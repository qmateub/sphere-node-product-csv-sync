_ = require 'underscore'
_.mixin require('underscore-mixins')
Promise = require 'bluebird'
{SphereClient, ProductSync, Errors} = require 'sphere-node-sdk'
{Repeater} = require 'sphere-node-utils'
CONS = require './constants'
GLOBALS = require './globals'
Validator = require './validator'
Mapping = require './mapping'
QueryUtils = require './queryutils'
MatchUtils = require './matchutils'

# API Types
Types = require './types'
Categories = require './categories'
CustomerGroups = require './customergroups'
Taxes = require './taxes'
Channels = require './channels'

# TODO:
# - better organize subcommands / classes / helpers
# - don't save partial results globally, instead pass them around to functions that need them
# - JSDoc
class Import

  constructor: (options = {}) ->
    if options.config #for easier unit testing
      @client = new SphereClient options
      @client.setMaxParallel 10
      @sync = new ProductSync
      @repeater = new Repeater attempts: 3

    # TODO: move initialisation somewhere else
    options.types = new Types()
    options.customerGroups = new CustomerGroups()
    options.categories = new Categories()
    options.taxes = new Taxes()
    options.channels = new Channels()

    @validator = new Validator(options)
    @map = new Mapping(options)
    @publishProducts = false
    @continueOnProblems = options.continueOnProblems
    @allowRemovalOfVariants = false
    @updatesOnly = false
    @dryRun = false
    @blackListedCustomAttributesForUpdate = []
    @customAttributeNameToMatch = undefined
    @matchBy = CONS.HEADER_ID

  # current workflow:
  # - parse csv
  # - validate csv
  # - map all parsed products
  # - get all existing products
  # - create/update products based on matches
  #
  # ideally workflow:
  # - get all product types, categories, customer groups, taxes, channels (maybe get them ondemand?)
  # - stream csv -> chunk (100)
  # - base csv validation of chunk
  # - map products to json in chunk
  # - lookup mapped products in sphere (depending on given matcher - id, sku, slug, custom attribute)
  # - validate products against their product types (we might not have to product type before)
  # - create/update products based on matches
  # - next chunk
  import: (fileContent) ->
    @validator.parse fileContent
    .then (parsed) =>
      console.warn "CSV file with #{parsed.count} row(s) loaded."
      @map.header = parsed.header
      productsRows = @validator.validateOffline(parsed.data)
      if _.size(@validator.errors) isnt 0
        return Promise.reject @validator.errors
      else
        @validator.validateOnline()
        .then (rawProducts) =>
          if _.size(@validator.errors) isnt 0
            return Promise.reject @validator.errors

          console.warn "Mapping #{_.size rawProducts} product(s) ..."
          products = rawProducts.map((p) => @map.mapProduct p)

          if _.size(@map.errors) isnt 0
            return Promise.reject @map.errors
          console.warn "Mapping done. About to process existing product(s) ..."

          p = if @validator.updateVariantsOnly
            p = (p) => @processProductsBasesOnSkus(p)
          else
            (p) => @processProducts(p)
          Promise.map(_.batchList(products, 20), p, { concurrency: 20 })
          .then((results) => results.reduce((agg, r) ->
            agg.concat(r)
          , []))

  processProducts: (products) ->
    filterInput = QueryUtils.mapMatchFunction(@matchBy)(products)
    console.warn "filterInput", filterInput
    @client.productProjections.staged().where(filterInput).fetch()
    .then (payload) =>
      existingProducts = payload.body.results
      console.warn "existingProducts", existingProducts
      console.warn "Comparing against #{payload.body.count} existing product(s) ..."
      matchFn = MatchUtils.initMatcher @matchBy, existingProducts
      productsToUpdate =
      if @validator.updateVariantsOnly
        # TODO: reactive this - currently broken!
        @mapVariantsBasedOnSKUs existingProducts, products
      else
        products
      console.warn "Processing #{_.size productsToUpdate} product(s) ..."
      @createOrUpdate(productsToUpdate, @validator.types, matchFn)
    .then (result) ->
      # TODO: resolve with a summary of the import
      console.warn "Finished processing #{_.size result} product(s)"
      Promise.resolve result

  processProductsBasesOnSkus: (products) ->
    filterInput = QueryUtils.mapMatchFunction("sku")(products)
    @client.productProjections.staged().where(filterInput).fetch()
    .then((payload) =>
      existingProducts = payload.body.results
      console.warn "Comparing against #{payload.body.count} existing product(s) ..."
      matchFn = MatchUtils.initMatcher("sku", existingProducts)
      productsToUpdate = @mapVariantsBasedOnSKUs(existingProducts, products)
      console.warn "productsToUpdate", _.prettify(productsToUpdate)
      Promise.all(_.map(productsToUpdate, (entry) =>
        @repeater.execute( =>
          existingProduct = matchFn(entry)
          if existingProduct?
            @update(entry.product, existingProduct, [], entry.header, entry.rowIndex)
          else
            console.warn("Ignoring not matched product")
        , (e) ->
          if e.code is 504
            console.warn 'Got a timeout, will retry again...'
            Promise.resolve() # will retry in case of Gateway Timeout
          else
            Promise.reject e)))
      .then((result) ->
        console.warn "Finished processing #{_.size result} product(s)"
        Promise.resolve result
      )
    )

  mapVariantsBasedOnSKUs: (existingProducts, products) ->
    console.warn "Mapping variants for #{_.size products} product type(s) ..."
    # console.warn "existingProducts", _.prettify(existingProducts)
    # console.warn "products", _.prettify(products)
    [sku2index, sku2variantInfo] = existingProducts.reduce((aggr, p, i) ->
      ([p.masterVariant].concat(p.variants)).reduce(([s2i, s2v], v, vi) ->
        s2i[v.sku] = i
        s2v[v.sku] = {
          index: vi - 1, # we reduce by one because of the masterVariant
          id: v.id
        }
        [s2i, s2v]
      , aggr)
    , [{}, {}])
    console.warn "sku2index", _.prettify(sku2index)
    console.warn "sku2variantInfo", _.prettify(sku2variantInfo)
    productsToUpdate = {}
    _.each products, (entry) =>
      variant = entry.product.masterVariant
      console.warn "variant", entry
      productIndex = sku2index[variant.sku]
      console.warn "variant.sku", variant.sku
      console.warn "productIndex", productIndex
      if productIndex?
        existingProduct = productsToUpdate[productIndex]?.product or _.deepClone existingProducts[productIndex]

        variantInfo = sku2variantInfo[variant.sku]
        variant.id = variantInfo.id
        if variant.id is 1
          existingProduct.masterVariant = variant
        else
          existingProduct.variants[variantInfo.index] = variant
        productsToUpdate[productIndex] =
          product: existingProduct
          header: entry.header
          rowIndex: entry.rowIndex
      else
        console.warn "Ignoring variant as no match by SKU found for: ", variant
    _.map productsToUpdate

  changeState: (publish = true, remove = false, filterFunction) ->
    @publishProducts = true

    @client.productProjections.staged(remove or publish).perPage(500).process (result) =>
      existingProducts = result.body.results

      console.warn "Found #{_.size existingProducts} product(s) ..."
      filteredProducts = _.filter existingProducts, filterFunction
      console.warn "Filtered #{_.size filteredProducts} product(s)."

      if _.size(filteredProducts) is 0
        # Q 'Nothing to do.'
        Promise.resolve()
      else
        posts = _.map filteredProducts, (product) =>
          if remove
            @deleteProduct(product, 0)
          else
            @publishProduct(product, 0, publish)

        action = if publish then 'Publishing' else 'Unpublishing'
        action = 'Deleting' if remove
        console.warn "#{action} #{_.size posts} product(s) ..."
        Promise.all(posts)
    .then (result) ->
      filteredResult = _.filter result, (r) -> r
      # TODO: resolve with a summary of the import
      console.warn "Finished processing #{_.size filteredResult} products"
      if _.size(filteredResult) is 0
        Promise.resolve 'Nothing to do'
      else
        Promise.resolve filteredResult

  createOrUpdate: (products, types, matchFn) ->
    Promise.all _.map products, (entry) =>
      @repeater.execute =>
        existingProduct = matchFn(entry)
        if existingProduct?
          @update(entry.product, existingProduct, types.id2SameForAllAttributes, entry.header, entry.rowIndex)
        else
          @create(entry.product, entry.rowIndex)
      , (e) ->
        if e.code is 504
          console.warn 'Got a timeout, will retry again...'
          Promise.resolve() # will retry in case of Gateway Timeout
        else
          Promise.reject e

  _isBlackListedForUpdate: (attributeName) ->
    if _.isEmpty @blackListedCustomAttributesForUpdate
      false
    else
      _.contains @blackListedCustomAttributesForUpdate, attributeName

  update: (product, existingProduct, id2SameForAllAttributes, header, rowIndex) ->
    allSameValueAttributes = id2SameForAllAttributes[product.productType.id]
    config = [
      { type: 'base', group: 'white' }
      { type: 'references', group: 'white' }
      { type: 'attributes', group: 'white' }
      { type: 'variants', group: 'white' }
      { type: 'categories', group: 'white' }
    ]
    if header.has(CONS.HEADER_PRICES)
      config.push { type: 'prices', group: 'white' }
    else
      config.push { type: 'prices', group: 'black' }
    if header.has(CONS.HEADER_IMAGES)
      config.push { type: 'images', group: 'white' }
    else
      config.push { type: 'images', group: 'black' }

    filtered = @sync.config(config)
    .buildActions(product, existingProduct, allSameValueAttributes)
    .filterActions (action) =>
      # console.warn "ACTION", action
      switch action.action
        when 'setAttribute', 'setAttributeInAllVariants'
          (header.has(action.name) or header.hasLanguageForCustomAttribute(action.name)) and not
          @_isBlackListedForUpdate(action.name)
        when 'changeName' then header.has(CONS.HEADER_NAME) or header.hasLanguageForBaseAttribute(CONS.HEADER_NAME)
        when 'changeSlug' then header.has(CONS.HEADER_SLUG) or header.hasLanguageForBaseAttribute(CONS.HEADER_SLUG)
        when 'setDescription' then header.has(CONS.HEADER_DESCRIPTION) or header.hasLanguageForBaseAttribute(CONS.HEADER_DESCRIPTION)
        when 'setMetaTitle' then header.has(CONS.HEADER_META_TITLE) or header.hasLanguageForBaseAttribute(CONS.HEADER_META_TITLE)
        when 'setMetaDescription' then header.has(CONS.HEADER_META_DESCRIPTION) or header.hasLanguageForBaseAttribute(CONS.HEADER_META_DESCRIPTION)
        when 'setMetaKeywords' then header.has(CONS.HEADER_META_KEYWORDS) or header.hasLanguageForBaseAttribute(CONS.HEADER_META_KEYWORDS)
        when 'addToCategory', 'removeFromCategory' then header.has(CONS.HEADER_CATEGORIES)
        when 'setTaxCategory' then header.has(CONS.HEADER_TAX)
        when 'setSKU' then header.has(CONS.HEADER_SKU)
        when 'addVariant', 'addPrice', 'removePrice', 'changePrice', 'addExternalImage', 'removeImage' then true
        when 'removeVariant' then @allowRemovalOfVariants
        else throw Error "The action '#{action.action}' is not supported. Please contact the SPHERE.IO team!"

    if @dryRun
      if filtered.shouldUpdate()
        Promise.resolve "[row #{rowIndex}] DRY-RUN - updates for #{existingProduct.id}:\n#{_.prettify filtered.getUpdatePayload()}"
      else
        Promise.resolve "[row #{rowIndex}] DRY-RUN - nothing to update."
    else
      if filtered.shouldUpdate()
        @client.products.byId(filtered.getUpdateId()).update(filtered.getUpdatePayload())
        .then (result) =>
          @publishProduct(result.body, rowIndex)
          .then -> Promise.resolve "[row #{rowIndex}] Product updated."
        .catch (err) =>
          msg = "[row #{rowIndex}] Problem on updating product:\n#{_.prettify err}\n#{_.prettify err.body}"
          if @continueOnProblems
            Promise.resolve "#{msg} - ignored!"
          else
            Promise.reject msg
      else
        Promise.resolve "[row #{rowIndex}] Product update not necessary."


  create: (product, rowIndex) ->
    if @dryRun
      Promise.resolve "[row #{rowIndex}] DRY-RUN - create new product."
    else if @updatesOnly
      Promise.resolve "[row #{rowIndex}] UPDATES ONLY - nothing done."
    else
      @client.products.create(product)
      .then (result) =>
        @publishProduct(result.body, rowIndex)
        .then -> Promise.resolve "[row #{rowIndex}] New product created."
      .catch (err) =>
        msg = "[row #{rowIndex}] Problem on creating new product:\n#{_.prettify err}\n#{_.prettify err.body}"
        if @continueOnProblems
          Promise.resolve "#{msg} - ignored!"
        else
          Promise.reject msg

  publishProduct: (product, rowIndex, publish = true) ->
    action = if publish then 'publish' else 'unpublish'
    if not @publishProducts
      Promise.resolve "Do not #{action}."
    else if publish and product.published and not product.hasStagedChanges
      Promise.resolve "[row #{rowIndex}] Product is already published - no staged changes."
    else
      data =
        id: product.id
        version: product.version
        actions: [
          action: action
        ]
      @client.products.byId(product.id).update(data)
      .then (result) ->
        Promise.resolve "[row #{rowIndex}] Product #{action}ed."
      .catch (err) =>
        if @continueOnProblems
          Promise.resolve "[row #{rowIndex}] Product is already #{action}ed."
        else
          Promise.reject "[row #{rowIndex}] Problem on #{action}ing product:\n#{_.prettify err}\n#{_.prettify err.body}"

  deleteProduct: (product, rowIndex) ->
    @client.products.byId(product.id).delete(product.version)
    .then ->
      Promise.resolve "[row #{rowIndex}] Product deleted."
    .catch (err) ->
      Promise.reject "[row #{rowIndex}] Error on deleting product:\n#{_.prettify err}\n#{_.prettify err.body}"

module.exports = Import
