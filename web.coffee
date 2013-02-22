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
url     = require("url")
uuid    = require("node-uuid")

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

app.get "/apps/:app/bundle", (req, res) ->
  return res.send("must authenticate", 403) unless req.user
  app = req.params.app
  api = heroku.init(req.user)
  log.start "download", app:app, (log) ->
    api.get "/apps/#{app}/release_slug", (err, release) ->
      return res.send(release.error, 403) if release.error
      fetch_slug release.slug_url, (err, slug) ->
        return res.send(err, 403) if err
        convert_to_tgz slug, (err, tgz) ->
          return res.send(err, 403) if err
          api.get "/apps/#{app}/config_vars", (err, config) ->
            return res.send(err, 403) if err
            inject_env tgz, config, (err, tgz) ->
              log.success()
              res.sendfile tgz

app.post "/apps/:app/bundle", (req, res) ->
  return res.send("must specify bundle", 403) unless req.files.bundle
  app = req.params.app
  api = heroku.init(req.user)
  log.start "upload", app:app, (log) ->
    api.get "/apps/#{app}/releases/new", (err, release) ->
      extract_slug_env req.files.bundle.path, (err, slug, env) ->
        fs.stat slug, (err, stats) ->
          slug_stream = fs.createReadStream(slug)
          slug_stream.on "open", ->
            options = url.parse(release.slug_put_url)
            options.method = "PUT"
            options.headers = { "Content-Length":stats.size }
            s3_req = http.request options, (s3_res) ->
              payload = coffee.helpers.merge release,
                slug_version: 2
                run_deploy_hooks: false
                user: req.body.user || "unknown@example.org"
                release_descr: req.body.description || "generic import description"
                head: uuid.v4()
              api.put "/apps/#{app}/config_vars", env, (err, test) ->
                api.post "/apps/#{app}/releases", payload, (err, release) ->
                  log.success()
                  res.send JSON.stringify(release)
            slug_stream.pipe s3_req

app.listen (process.env.PORT || 5000)

extract_slug_env = (bundle, cb) ->
  log.start "extract_slug_env", (log) ->
    temp.mkdir "extract", (err, path) ->
      exec "tar xzf #{bundle}", cwd:path, (err, stdout, stderr) ->
        read_env "#{path}/.env", (err, env) ->
          fs.unlink "#{path}/.env", (err) ->
            temp.mkdir "recombine", (err, rec_path) ->
              exec "mksquashfs #{path} #{rec_path}/slug.img -all-root", (err, stdout, stderr) ->
                log.success()
                cb null, "#{rec_path}/slug.img", env

read_env = (file, cb) ->
  fs.readFile file, (err, data) ->
    cb err, data.toString().split("\n").reduce(
      (ax, line) ->
        parts = line.split("=")
        key = parts.shift()
        ax[key] = parts.join("=") unless key is ""
        ax
      {})

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
        log.error new Error("unknown slug type: #{stdout}")
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
          exec "gzip -1 tgz #{tar}", (err, stdout, stderr) ->
            tgz = tar.replace(/\.tar$/, ".tar.gz")
            log.success()
            cb null, tgz
