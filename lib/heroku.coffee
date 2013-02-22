coffee = require("coffee-script")
https  = require("https")
url    = require("url")

https.globalAgent.maxSockets = 5000

class Heroku

  constructor: (@key) ->

  get: (path, options={}, cb) ->
    if options instanceof Function
      cb = options
      options = {}
    get =
      hostname: "api.heroku.com"
      port: 443
      path: path
      query: options.query || {}
      auth: ":#{@key}"
      headers: coffee.helpers.merge("User-Agent":"app-state/0.1", (options.headers || {}))
    https.get get, (res) ->
      buffer = ""
      res.on "data", (data) -> buffer += data
      res.on "end",         -> cb null, JSON.parse(buffer)

  post: (path, payload, options={}, cb) ->
    if options instanceof Function
      cb = options
      options = {}
    post =
      method: "POST"
      hostname: "api.heroku.com"
      port: 443
      path: path
      auth: ":#{@key}"
      headers: coffee.helpers.merge("User-Agent":"app-state/0.1", (options.headers || {}))
    req = https.request post, (res) ->
      buffer = ""
      res.on "data", (data) -> buffer += data
      res.on "end",         -> cb null, JSON.parse(buffer)
    req.write JSON.stringify(payload)
    req.end()

  put: (path, payload, options={}, cb) ->
    if options instanceof Function
      cb = options
      options = {}
    post =
      method: "PUT"
      hostname: "api.heroku.com"
      port: 443
      path: path
      auth: ":#{@key}"
      headers: coffee.helpers.merge("User-Agent":"app-state/0.1", (options.headers || {}))
    req = https.request post, (res) ->
      buffer = ""
      res.on "data", (data) -> buffer += data
      res.on "end",         -> cb null, JSON.parse(buffer)
    req.write JSON.stringify(payload)
    req.end()

exports.init = (key) ->
  new Heroku(key)
