async   = require("async")
coffee  = require("coffee-script")
exec    = require("child_process").exec
express = require("express")
heroku  = require("./lib/heroku")
http    = require("http")
fs      = require("fs")
log     = require("./lib/logger").init("slug-converter")
spawn   = require("child_process").spawn
temp    = require("temp")

delay = (ms, cb) -> setTimeout  cb, ms
every = (ms, cb) -> setInterval cb, ms

express.logger.format "method",     (req, res) -> req.method.toLowerCase()
express.logger.format "url",        (req, res) -> req.url.replace('"', "&quot")
express.logger.format "user-agent", (req, res) -> (req.headers["user-agent"] || "").replace('"', "")

app = express()

app.disable "x-powered-by"

app.use express.logger
  buffer: false
  format: "ns=\"slug-converter\" measure=\"http.:method\" source=\":url\" status=\":status\" elapsed=\":response-time\" from=\":remote-addr\" agent=\":user-agent\""
app.use express.cookieParser()
app.use express.bodyParser()
app.use express.basicAuth (user, pass, cb) -> cb(null, pass)
app.use app.router
app.use (err, req, res, next) -> res.send 500, (if err.message? then err.message else err)

app.get "/", (req, res) ->
  res.send "ok"

app.get "/apps/:app/bundle.tgz", (req, res) ->
  return res.send("must authenticate", 403) unless req.user
  app = req.params.app
  api = heroku.init(req.user)
  log.start "fetch", app:app, (log) ->
    api.get "/apps/#{app}/release_slug", (err, release) ->
      fetch_slug release.slug_url, (err, slug) ->
        return res.send(err, 403) if err
        convert_to_tgz slug, (err, tgz) ->
          return res.send(err, 403) if err
          api.get "/apps/#{app}/config_vars", (err, config) ->
            return res.send(err, 403) if err
            inject_env tgz, config, (err, tgz) ->
              log.success()
              res.sendfile tgz

app.listen (process.env.PORT || 5000)

fetch_slug = (url, cb) ->
  log.start "fetch_slug", (log) ->
    slug = temp.createWriteStream suffix:".img"
    req  = http.get url, (res) ->
      res.on "data", (data) -> slug.write data
      res.on "end",         ->
        slug.end()
        log.success()
        cb(null, slug.path)
    req.on "error", (err) ->
      log.error err
      cb err

convert_to_tgz = (slug, cb) ->
  log.start "convert_to_tgz", (log) ->
    exec "file #{slug}", (err, stdout, stderr) ->
      if /squashfs filesystem/i.test(stdout)
        temp.mkdir "unsquash", (err, path) ->
          exec "unsquashfs -d #{path}/slug #{slug}", (err, stdout, stderr) ->
            exec "fakeroot tar czf #{path}/slug.tgz .", cwd:"#{path}/slug", (err, stdout, stderr) ->
              log.success type:"squash"
              cb null, "#{path}/slug.tgz"
      else if /gzip compressed/.test(stdout)
        tgz = slug.replace(/\.img$/, '.tgz')
        fs.rename slug, tgz, (err) ->
          log.success type:"tgz"
          cb null, tgz
      else
        log.error "unknown slug type"
        cb "error fetching slug"

inject_env = (tgz, config, cb) ->
  log.start "inject_env", (log) ->
    temp.mkdir "inject", (err, path) ->
      env = fs.createWriteStream "#{path}/.env"
      env.write "#{key}=#{val}\n" for key, val of config
      env.end()
      exec "gzip -d #{tgz}", (err, stdout, stderr) ->
        tar = tgz.replace(/\.tgz$/, ".tar")
        exec "fakeroot tar rf #{tar} ./.env", cwd:path, (err, stdout, stderr) ->
          exec "gzip -9 tgz #{tar}", (err, stdout, stderr) ->
            tgz = tar.replace(/\.tar$/, ".tar.gz")
            log.success()
            cb null, tgz
