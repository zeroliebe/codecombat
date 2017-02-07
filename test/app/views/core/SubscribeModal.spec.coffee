SubscribeModal = require 'views/core/SubscribeModal'
Products = require 'collections/Products'

productList = [
  {
    name: 'basic_subscription'
    amount: 100
    gems: 3500
    planID: 'basic'
  }

  {
    name: 'year_subscription'
    amount: 1000
    gems: 42000
  }

  {
    name: 'lifetime_subscription'
    amount: 1000
    gems: 42000
  }
]

describe 'SubscribeModal', ->

  modal = null

  beforeEach ->
    modal = new SubscribeModal({products: new Products(productList)})
    modal.render()

  afterEach ->
    modal.stopListening()

  it '(demo)', ->
    jasmine.demoModal(modal)
