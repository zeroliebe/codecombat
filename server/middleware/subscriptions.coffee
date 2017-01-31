errors = require '../commons/errors'
wrap = require 'co-express'
Prepaid = require '../models/Prepaid'
log = require 'winston'
SubscriptionHandler = require('../handlers/subscription_handler')
Promise = require('bluebird')
SubscriptionHandler.checkForExistingSubscriptionAsync = Promise.promisify(SubscriptionHandler.checkForExistingSubscription)

subscribeWithPrepaidCode = wrap (req, res) ->
  { ppc } = req.body
  unless ppc and _.isString(ppc)
    throw new errors.UnprocessableEntity('You must provide a valid prepaid code.')

  prepaid = yield Prepaid.findOne({ code: ppc })
  unless prepaid
    throw new errors.NotFound('Prepaid not found')

  yield prepaid.redeem(req.user)
  res.send(req.user.toObject({req}))


subscribeUser = wrap (req, user) ->
  if (not req.user) or req.user.isAnonymous() or user.isAnonymous()
    throw new errors.Unauthorized('You must be signed in to subscribe.')

  if not req.user.get('email')
    throw new errors.Forbidden('Your account needs an email address to subscribe.')

  { token, prepaidCode } = req.body.stripe
  { customerID } = (user.get('stripe') or {})
  if not (token or customerID or prepaidCode)
    SubscriptionHandler.logSubscriptionError(user, 'Missing Stripe token or customer ID or prepaid code')
    throw new errors.UnprocessableEntity('Missing Stripe token or customer ID or prepaid code')

  # Get Stripe customer
  if customerID and token
    customer = yield stripe.customers.update(customerID, { card: token })
    if not customer
      # should not happen outside of test and production polluting each other
      SubscriptionHandler.logSubscriptionError(user, 'Cannot find customer: ' + customerID + '\n\n' + err)
      throw new errors.NotFound('Cannot find customer.')
    yield checkForCoupon(req, user, customer)

  else if customerID and not token
    customer = yield stripe.customers.retrieve(customerID)
    yield checkForCoupon(req, user, customer)

  else
    options = {
      email: user.get('email')
      metadata: { id: user.id, slug: user.get('slug') }
    }
    options.card = token if token?

    try
      customer = yield stripe.customers.create(options)
    catch err
      if err.type in ['StripeCardError', 'StripeInvalidRequestError']
        throw new errors.PaymentRequired('Card error')
      else
        throw err

    stripeInfo = _.cloneDeep(user.get('stripe') ? {})
    stripeInfo.customerID = customer.id
    user.set('stripe', stripeInfo)
    yield user.save()
    yield checkForCoupon(req, user, customer)


checkForCoupon = wrap (req, user, customer) ->
  
  { prepaidCode } = req.body?.stripe or {}
  
  if prepaidCode
    prepaid = yield Prepaid.findOne({code: prepaidCode})
    if not prepaid
      throw new errors.NotFound('Prepaid not found')
    unless prepaid.get('type') is 'subscription'
      throw new errors.Forbidden('Prepaid not for subscription')
    redeemers = prepaid.get('redeemers') ? []
    if redeemers.length >= prepaid.get('maxRedeemers')
      SubscriptionHandler.logSubscriptionError(user, "Prepaid #{prepaid.id} note active")
      throw new errors.Forbidden('Prepaid not active')
    { couponID } = prepaid.get('properties') or {}
    unless couponID
      SubscriptionHandler.logSubscriptionError(user, "Prepaid #{prepaid.id} has no couponID")
      throw new errors.InternalServerError('Database error.')
    if _.find(redeemers, (a) -> a.userID?.equals(user.get('_id')))
      SubscriptionHandler.logSubscriptionError(user, "Prepaid code already redeemed by #{user.id}")
      throw new errors.Forbidden('Prepaid code already redeemed')

    # Redeem prepaid code
    query = Prepaid.$where("'#{prepaid.get('_id').valueOf()}' === this._id.valueOf() && (!this.redeemers || this.redeemers.length < this.maxRedeemers)")
    redeemers.push {
      userID: user.get('_id')
      date: new Date()
    }
    update = { redeemers: redeemers }
    result = yield Prepaid.update(query, update, {})
    if result.nModified > 1
      @logSubscriptionError(user, "Prepaid nModified=#{result.nModified} error.")
      return done({res: 'Database error.', code: 500})
    if result.nModified < 1
      return done({res: 'Prepaid not active', code: 403})

    # Update user
    stripeInfo = _.cloneDeep(user.get('stripe') ? {})
    _.assign(stripeInfo, { prepaidCode, couponID })
    user.set('stripe', stripeInfo)
    yield SubscriptionHandler.checkForExistingSubscriptionAsync(req, user, customer, couponID)

  else
    couponID = user.get('stripe')?.couponID
    unless couponID or not user.get 'country'
      product = yield Product.findBasicSubscriptionForUser(user)
      unless product.name is 'basic_subscription'
        # We have a customized product for this country
        couponID = user.get 'country'
    yield SubscriptionHandler.checkForExistingSubscriptionAsync(req, user, customer, couponID)
        
module.exports = {
  subscribeWithPrepaidCode
  subscribeUser
}
