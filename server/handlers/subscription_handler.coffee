# Not paired with a document in the DB, just handles coordinating between
# the stripe property in the user with what's being stored in Stripe.

log = require 'winston'
MongoClient = require('mongodb').MongoClient
mongoose = require 'mongoose'
async = require 'async'
config = require '../../server_config'
Handler = require '../commons/Handler'
slack = require '../slack'
discountHandler = require './discount_handler'
Prepaid = require '../models/Prepaid'
User = require '../models/User'
{findStripeSubscription} = require '../lib/utils'
{getSponsoredSubsAmount} = require '../../app/core/utils'
StripeUtils = require '../lib/stripe_utils'
moment = require 'moment'
Product = require '../models/Product'
{formatDollarValue} = require '../../app/core/utils'

recipientCouponID = 'free'

class SubscriptionHandler extends Handler
  logSubscriptionError: (user, msg) ->
    log.warn "Subscription Error: #{user.get('slug')} (#{user._id}): '#{msg}'"

  getByRelationship: (req, res, args...) ->
    return @getStripeEvents(req, res) if args[1] is 'stripe_events'
    return @getStripeInvoices(req, res) if args[1] is 'stripe_invoices'
    return @getStripeSubscriptions(req, res) if args[1] is 'stripe_subscriptions'
    return @getSubscribers(req, res) if args[1] is 'subscribers'
    return @purchaseYearSale(req, res) if args[1] is 'year_sale'
    super(arguments...)

  getStripeEvents: (req, res) ->
    # console.log 'subscription_handler getStripeEvents', req.body?.options
    return @sendForbiddenError(res) unless req.user?.isAdmin()
    stripe.events.list req.body.options, (err, events) =>
      return @sendDatabaseError(res, err) if err
      @sendSuccess(res, events)

  getStripeInvoices: (req, res) ->
    # console.log 'subscription_handler getStripeInvoices'
    return @sendForbiddenError(res) unless req.user?.isAdmin()

    stripe.invoices.list req.body.options, (err, invoices) =>
      return @sendDatabaseError(res, err) if err
      @sendSuccess(res, invoices)

  getStripeSubscriptions: (req, res) ->
    # console.log 'subscription_handler getStripeSubscriptions'
    return @sendForbiddenError(res) unless req.user?.isAdmin()
    stripeSubscriptions = []
    createGetSubFn = (customerID, subscriptionID) =>
      (done) =>
        stripe.customers.retrieveSubscription customerID, subscriptionID, (err, subscription) =>
          # TODO: return error instead of ignore?
          unless err
            trimmedSubscription = _.pick(subscription, ['cancel_at_period_end', 'canceled_at', 'customerID', 'start', 'id', 'metadata'])
            stripeSubscriptions.push(trimmedSubscription)
          done()
    tasks = []
    for subscription in req.body.subscriptions
      tasks.push createGetSubFn(subscription.customerID, subscription.subscriptionID)
    async.parallel tasks, (err, results) =>
      return @sendDatabaseError(res, err) if err
      @sendSuccess(res, stripeSubscriptions)

  getSubscribers: (req, res) ->
    # console.log 'subscription_handler getSubscribers'
    return @sendForbiddenError(res) unless req.user?.isAdmin()
    subscriberUserIDs = req.body.ids or []

    User.find {_id: {$in: subscriberUserIDs}}, (err, users) =>
      return @sendDatabaseError(res, err) if err
      userMap = {}
      userMap[user.id] = user.toObject() for user in users

      try
        # Get conversion data directly from analytics database and add it to results
        url = "mongodb://#{config.mongo.analytics_host}:#{config.mongo.analytics_port}/#{config.mongo.analytics_db}"
        MongoClient.connect url, (err, db) =>
          if err
            log.debug 'Analytics connect error: ' + err
            return @sendDatabaseError(res, err)
          userEventMap = {}
          events = ['Finished subscription purchase', 'Show subscription modal']
          query = {$and: [{user: {$in: subscriberUserIDs}}, {event: {$in: events}}]}
          db.collection('log').find(query).sort({_id: -1}).each (err, doc) =>
            if err
              db.close()
              return @sendDatabaseError(res, err)
            if (doc)
              userEventMap[doc.user] ?= []
              userEventMap[doc.user].push doc
            else
              db.close()
              for userID, eventList of userEventMap
                finishedPurchase = false
                for event in eventList
                  finishedPurchase = true if event.event is 'Finished subscription purchase'
                  if finishedPurchase
                    if event.event is 'Show subscription modal' and event.properties?.level?
                      userMap[userID].conversion = event.properties.level
                      break
                    else if event.event is 'Show subscription modal' and event.properties?.label in ['buy gems modal', 'check private clan', 'create clan']
                      userMap[userID].conversion = event.properties.label
                      break
              @sendSuccess(res, userMap)
      catch err
        log.debug 'Analytics error:\n' + err
        @sendSuccess(res, userMap)

  purchaseYearSale: (req, res) ->
    return @sendForbiddenError(res) unless req.user?
    return @sendForbiddenError(res) if req.user?.get('stripe')?.sponsorID

    StripeUtils.getCustomer req.user, req.body.stripe?.token, (err, customer) =>
      if err
        @logSubscriptionError(req.user, "Purchase year sale get customer: #{JSON.stringify(err)}")
        return @sendDatabaseError(res, err)

      findStripeSubscription customer.id, subscriptionID: req.user.get('stripe')?.subscriptionID, (err, subscription) =>
        stripeSubscriptionPeriodEndDate = new Date(subscription.current_period_end * 1000) if subscription

        StripeUtils.cancelSubscriptionImmediately req.user, subscription, (err) =>
          if err
            @logSubscriptionError(user, "Purchase year sale Stripe cancel subscription error: #{JSON.stringify(err)}")
            return @sendDatabaseError(res, err)

          Product.find().exec (err, products) =>
            return @sendDatabaseError(res, err) if err

            product = _.find(products, (p) -> p.get('name') is 'year_subscription')
            return @sendNotFoundError(res, 'year_subscription product not found') if not product

            metadata =
              type: req.body.type
              userID: req.user._id + ''
              gems: product.get('gems')
              timestamp: parseInt(req.body.stripe?.timestamp)
              description: req.body.description

            StripeUtils.createCharge req.user, product.get('amount'), metadata, (err, charge) =>
              if err
                @logSubscriptionError(req.user, "Purchase year sale create charge: #{JSON.stringify(err)}")
                return @sendDatabaseError(res, err)

              StripeUtils.createPayment req.user, charge, {}, (err, payment) =>
                if err
                  @logSubscriptionError(req.user, "Purchase year sale create payment: #{JSON.stringify(err)}")
                  return @sendDatabaseError(res, err)

                # Add terminal subscription to User with extensions for existing subscriptions
                stripeInfo = _.cloneDeep(req.user.get('stripe') ? {})
                endDate = new Date()
                if stripeSubscriptionPeriodEndDate
                  endDate = stripeSubscriptionPeriodEndDate
                else if _.isString(stripeInfo.free) and new Date() < new Date(stripeInfo.free)
                  endDate = new Date(stripeInfo.free)
                endDate.setUTCFullYear(endDate.getUTCFullYear() + 1)
                stripeInfo.free = endDate.toISOString().substring(0, 10)
                req.user.set('stripe', stripeInfo)

                # Add year's worth of gems to User
                purchased = _.clone(req.user.get('purchased'))
                purchased ?= {}
                purchased.gems ?= 0
                purchased.gems += parseInt(charge.metadata.gems) if charge.metadata.gems
                req.user.set('purchased', purchased)

                req.user.save (err, user) =>
                  if err
                    @logSubscriptionError(req.user, "User save error: #{JSON.stringify(err)}")
                    return @sendDatabaseError(res, err)
                  try
                    msg = "#{req.user.get('email')} paid #{formatDollarValue(payment.get('amount')/100)} for year campaign subscription"
                    slack.sendSlackMessage msg, ['tower']
                  catch error
                    @logSubscriptionError(req.user, "Year sub sale Slack tower msg error: #{JSON.stringify(error)}")
                  @sendSuccess(res, user)


  unsubscribeUser: (req, user, done) ->
    # Check if user is subscribing someone else
    return @unsubscribeRecipient(req, user, done) if req.body.stripe?.unsubscribeEmail?

    stripeInfo = _.cloneDeep(user.get('stripe') ? {})
    stripe.customers.cancelSubscription stripeInfo.customerID, stripeInfo.subscriptionID, { at_period_end: true }, (err) =>
      if err
        @logSubscriptionError(user, 'Stripe cancel subscription error. ' + err)
        return done({res: 'Database error.', code: 500})
      delete stripeInfo.planID
      user.set('stripe', stripeInfo)
      req.body.stripe = stripeInfo
      user.save (err) =>
        if err
          @logSubscriptionError(user, 'User save unsubscribe error. ' + err)
          return done({res: 'Database error.', code: 500})
        done()

  unsubscribeRecipient: (req, user, done) ->
    return done({res: 'Database error.', code: 500}) unless req.body.stripe?.unsubscribeEmail?

    email = req.body.stripe.unsubscribeEmail.trim().toLowerCase()
    return done({res: 'Database error.', code: 500}) if _.isEmpty(email)

    deleteUserStripeProp = (user, propName) ->
      stripeInfo = _.cloneDeep(user.get('stripe') ? {})
      delete stripeInfo[propName]
      if _.isEmpty stripeInfo
        user.set 'stripe', undefined
      else
        user.set 'stripe', stripeInfo

    User.findOne {emailLower: email}, (err, recipient) =>
      if err
        @logSubscriptionError(user, "User lookup error. " + err)
        return done({res: 'Database error.', code: 500})
      unless recipient
        @logSubscriptionError(user, "Recipient #{email} not found.")
        return done({res: 'Database error.', code: 500})

      # Check recipient is currently sponsored
      stripeRecipient = recipient.get 'stripe' ? {}
      if stripeRecipient?.sponsorID isnt user.id
        @logSubscriptionError(user, "Recipient #{recipient.id} not sponsored by #{user.id}. ")
        return done({res: 'Can only unsubscribe sponsored subscriptions.', code: 403})

      # Find recipient subscription
      stripeInfo = _.cloneDeep(user.get('stripe') ? {})
      for sponsored in stripeInfo.recipients
        if sponsored.userID is recipient.id
          sponsoredEntry = sponsored
          break
      unless sponsoredEntry?
        @logSubscriptionError(user, 'Unable to find recipient subscription. ')
        return done({res: 'Database error.', code: 500})

      Product.findOne({name: 'basic_subscription'}).exec (err, product) =>
        return @sendDatabaseError(res, err) if err
        return @sendNotFoundError(res, 'basic_subscription product not found') if not product

        # Update recipient user
        deleteUserStripeProp(recipient, 'sponsorID')
        recipient.save (err) =>
          if err
            @logSubscriptionError(user, 'Recipient user save unsubscribe error. ' + err)
            return done({res: 'Database error.', code: 500})

          # Cancel Stripe subscription
          stripe.customers.cancelSubscription stripeInfo.customerID, sponsoredEntry.subscriptionID, (err) =>
            if err
              @logSubscriptionError(user, "Stripe cancel sponsored subscription failed. " + err)
              return done({res: 'Database error.', code: 500})

            # Update sponsor user
            _.remove(stripeInfo.recipients, (s) -> s.userID is recipient.id)
            delete stripeInfo.unsubscribeEmail
            user.set('stripe', stripeInfo)
            req.body.stripe = stripeInfo
            user.save (err) =>
              if err
                @logSubscriptionError(user, 'Sponsor user save unsubscribe error. ' + err)
                return done({res: 'Database error.', code: 500})

              return done() unless stripeInfo.sponsorSubscriptionID?

              # Update sponsored subscription quantity
              options =
                quantity: getSponsoredSubsAmount(product.get('amount'), stripeInfo.recipients.length, stripeInfo.subscriptionID?)
              stripe.customers.updateSubscription stripeInfo.customerID, stripeInfo.sponsorSubscriptionID, options, (err, subscription) =>
                if err
                  @logSubscriptionError(user, 'Sponsored subscription quantity update error. ' + JSON.stringify(err))
                  return done({res: 'Database error.', code: 500})
                done()

module.exports = new SubscriptionHandler()
