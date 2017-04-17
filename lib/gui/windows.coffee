_             = require("lodash")
uri           = require("url")
cyDesktop     = require("@cypress/core-desktop-gui")
contextMenu   = require("electron-context-menu")
BrowserWindow = require("electron").BrowserWindow
cwd           = require("../cwd")
user          = require("../user")
savedState    = require("../saved_state")

windows               = {}
recentlyCreatedWindow = false

getUrl = (type) ->
  switch type
    when "GITHUB_LOGIN"
      user.getLoginUrl()
    when "ABOUT"
      cyDesktop.getPathToAbout()
    when "DEBUG"
      cyDesktop.getPathToDebug()
    when "UPDATES"
      cyDesktop.getPathToUpdates()
    when "INDEX"
      cyDesktop.getPathToIndex()
    else
      throw new Error("No acceptable window type found for: '#{type}'")

getByType = (type) ->
  windows[type]

module.exports = {
  reset: ->
    windows = {}

  destroy: (type) ->
    if type and (win = getByType(type))
      win.destroy()

  get: (type) ->
    getByType(type) ? throw new Error("No window exists for: '#{type}'")

  showAll: ->
    _.invoke windows, "showInactive"

  hideAllUnlessAnotherWindowIsFocused: ->
    ## bail if we have another focused window
    ## or we are in the middle of creating a new one
    return if BrowserWindow.getFocusedWindow() or recentlyCreatedWindow

    ## else hide all windows
    _.invoke windows, "hide"

  getByWebContents: (webContents) ->
    BrowserWindow.fromWebContents(webContents)

  create: (options = {}) ->
    _.defaultsDeep(options, {
      x:               null
      y:               null
      show:            true
      frame:           true
      width:           null
      height:          null
      winWidth:        null
      minHeight:       null
      devTools:        false
      trackState:      false
      contextMenu:     false
      recordFrameRate: null
      onPaint:         null
      onFocus: ->
      onBlur: ->
      onClose: ->
      onCrashed: ->
      onNewWindow: ->
      webPreferences:  {
        chromeWebSecurity:    true
        nodeIntegration:      false
        backgroundThrottling: false
      }
    })

    if options.show is false
      options.frame = false
      options.webPreferences.offscreen = true

    if options.chromeWebSecurity is false
      options.webPreferences.webSecurity = false

    win = new BrowserWindow(options)

    win.on "blur", ->
      options.onBlur.apply(win, arguments)

    win.on "focus", ->
      options.onFocus.apply(win, arguments)

    win.once "closed", ->
      win.removeAllListeners()
      options.onClose.apply(win, arguments)

    win.webContents.on "crashed", ->
      options.onCrashed.apply(win, arguments)

    win.webContents.on "new-window", ->
      options.onNewWindow.apply(win, arguments)

    if ts = options.trackState
      @trackState(win, ts)

    ## open dev tools if they're true
    if options.devTools
      ## and possibly detach dev tools if true
      win.webContents.openDevTools()

    if options.contextMenu
      ## adds context menu with copy, paste, inspect element, etc
      contextMenu({
        showInspectElement: true
        window: win
      })

    if options.onPaint
      setFrameRate = (num) ->
        if win.webContents.getFrameRate() isnt num
          win.webContents.setFrameRate(num)

      win.webContents.on "paint", (event, dirty, image) ->
        if fr = options.recordFrameRate
          setFrameRate(fr)

        options.onPaint.apply(win, arguments)

    win

  open: (options = {}) ->
    ## if we already have a window open based
    ## on that type then just show + focus it!
    if win = getByType(options.type)
      win.show()

      if options.type is "GITHUB_LOGIN"
        err = new Error
        err.alreadyOpen = true
        return Promise.reject(err)
      else
        return Promise.resolve(win)

    recentlyCreatedWindow = true

    _.defaults options, {
      width:  600
      height: 500
      show:   true
      url:    getUrl(options.type)
      webPreferences: {
        preload: cwd("lib", "ipc", "ipc.js")
      }
    }

    urlChanged = (url, resolve) ->
      parsed = uri.parse(url, true)

      if code = parsed.query.code
        ## there is a bug with electron
        ## crashing when attemping to
        ## destroy this window synchronously
        _.defer -> win.destroy()

        resolve(code)

    # if args.transparent and args.show
    #   {width, height} = args

    #   args.show = false
    #   args.width = 0
    #   args.height = 0

    win = @create(options)

    windows[options.type] = win

    win.webContents.id = _.uniqueId("webContents")

    win.once "closed", ->
      ## slice the window out of windows reference
      delete windows[options.type]

    ## enable our url to be a promise
    ## and wait for this to be resolved
    Promise
    .resolve(options.url)
    .then (url) ->
      # if width and height
      #   ## width and height are truthy when
      #   ## transparent: true is sent
      #   win.webContents.once "dom-ready", ->
      #     win.setSize(width, height)
      #     win.show()

      ## navigate the window here!
      win.loadURL(url)

      ## reset this back to false
      recentlyCreatedWindow = false

      if options.type is "GITHUB_LOGIN"
        new Promise (resolve, reject) ->
          win.webContents.on "will-navigate", (e, url) ->
            urlChanged(url, resolve)

          win.webContents.on "did-get-redirect-request", (e, oldUrl, newUrl) ->
            urlChanged(newUrl, resolve)
      else
        Promise.resolve(win)

  trackState: (win, keys) ->
    win.on "resize", _.debounce ->
      [width, height] = win.getSize()
      [x, y] = win.getPosition()
      newState = {}
      newState[keys.width] = width
      newState[keys.height] = height
      newState[keys.x] = x
      newState[keys.y] = y
      savedState.set(newState)
    , 500

    win.on "moved", _.debounce ->
      [x, y] = win.getPosition()
      newState = {}
      newState[keys.x] = x
      newState[keys.y] = y
      savedState.set(newState)
    , 500

    win.webContents.on "devtools-opened", ->
      newState = {}
      newState[keys.devTools] = true
      savedState.set(newState)

    win.webContents.on "devtools-closed", ->
      newState = {}
      newState[keys.devTools] = false
      savedState.set(newState)

}
