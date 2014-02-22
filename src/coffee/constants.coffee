constants =
  # This isn't a constants - TODO move it to proper location
  DEFAULT_LANGUAGE: 'en'

  HEADER_ID: 'id'
  HEADER_PRODUCT_TYPE: 'productType'
  HEADER_NAME: 'name'
  HEADER_DESCRIPTION: 'description'
  HEADER_VARIANT_ID: 'variantId'
  HEADER_SLUG: 'slug'
  HEADER_SKU: 'sku'
  HEADER_PRICES: 'prices'
  HEADER_TAX: 'tax'
  HEADER_CATEGORIES: 'categories'
  HEADER_IMAGES: 'images'
  HEADER_IMAGE_LABELS: 'imageLabels'
  HEADER_IMAGE_DIMENSIONS: 'imageDimensions'
  HEADER_PUBLISH: 'publish'

  DELIM_HEADER_LANGUAGE: '.'
  DELIM_MULTI_VALUE: ';'
  DELIM_CATEGORY_CHILD: '>'

  ATTRIBUTE_TYPE_SET: 'set'
  ATTRIBUTE_TYPE_LTEXT: 'ltext'
  ATTRIBUTE_TYPE_ENUM: 'enum'
  ATTRIBUTE_TYPE_LENUM: 'lenum'
  ATTRIBUTE_TYPE_NUMBER: 'number'
  ATTRIBUTE_TYPE_MONEY: 'money'

  ATTRIBUTE_CONSTRAINT_SAME_FOR_ALL: 'SameForAll'

  REGEX_PRICE: new RegExp /^(([A-Za-z]{2})-|)([A-Z]{3}) (\d+)( (\w*)|)(#(\w+)|)$/
  REGEX_MONEY: new RegExp /^([A-Z]{3}) (\d+)$/
  REGEX_NUMBER: new RegExp /^\d+$/


for name,value of constants
  exports[name] = value

exports.BASE_HEADERS = [
  constants.HEADER_PRODUCT_TYPE,
  constants.HEADER_VARIANT_ID
]

exports.BASE_LOCALIZED_HEADERS = [
  constants.HEADER_NAME,
  constants.HEADER_DESCRIPTION
  constants.HEADER_SLUG,
  'metaTitle',
  'metaDescription',
  'metaKeywords'
]
