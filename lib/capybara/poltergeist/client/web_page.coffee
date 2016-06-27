class Poltergeist.WebPage
  @CALLBACKS = ['onConsoleMessage','onError',
                'onLoadFinished', 'onInitialized', 'onLoadStarted',
                'onResourceRequested', 'onResourceReceived', 'onResourceError', 'onResourceTimeout',
                'onNavigationRequested', 'onUrlChanged', 'onPageCreated',
                'onClosing', 'onCallback']

  @DELEGATES = ['url', 'open', 'sendEvent', 'uploadFile', 'render', 'close',
                'renderBase64', 'goBack', 'goForward', 'reload']

  # @COMMANDS  = ['currentUrl', 'find', 'nodeCall', 'documentSize',
  @COMMANDS  = ['find', 'nodeCall', 'documentSize',
                'beforeUpload', 'afterUpload', 'clearLocalStorage']

  @EXTENSIONS = []

  constructor: (@_native, settings) ->
    @_native or= require('webpage').create()

    @id              = 0
    @source          = null
    @closed          = false
    @state           = 'default'
    @urlWhitelist    = []
    @urlBlacklist    = []
    @errors          = []
    @_networkTraffic = {}
    @_tempHeaders    = {}
    @_blockedUrls    = []
    @_requestedResources = {}
    @_responseHeaders = []
    @_tempHeadersToRemoveOnRedirect = {}
    @_asyncResults = {}
    @_asyncEvaluationId = 0

    @setSettings(settings)

    for callback in WebPage.CALLBACKS
      @bindCallback(callback)

  for command in @COMMANDS
    do (command) =>
      @prototype[command] =
        (args...) -> @runCommand(command, args)

  for delegate in @DELEGATES
    do (delegate) =>
      @prototype[delegate] =
        -> @_native[delegate].apply(@_native, arguments)

  setSettings: (settings = {})->
    @_native.settings[setting] = value for setting, value of settings

  onInitializedNative: ->
    @id += 1
    @source = null
    @injectAgent()
    @removeTempHeaders()
    @removeTempHeadersForRedirect()
    @setScrollPosition(left: 0, top: 0)

  onClosingNative: ->
    @handle = null
    @closed = true

  onConsoleMessageNative: (message) ->
    if message == '__DOMContentLoaded'
      @source = @_native.content
      false
    else
      console.log(message)

  onLoadStartedNative: ->
    @state = 'loading'
    @requestId = @lastRequestId
    @_requestedResources = {}

  onLoadFinishedNative: (@status) ->
    @state = 'default'
    @source or= @_native.content

  onErrorNative: (message, stack) ->
    stackString = message

    stack.forEach (frame) ->
      stackString += "\n"
      stackString += "    at #{frame.file}:#{frame.line}"
      stackString += " in #{frame.function}" if frame.function && frame.function != ''

    @errors.push(message: message, stack: stackString)
    return true

  onCallbackNative: (data) ->
    @_asyncResults[data['command_id']] = data['command_result']
    true

  onResourceRequestedNative: (request, net) ->
    @_networkTraffic[request.id] = {
      request:       request,
      responseParts: []
      error: null
    }

    if @_blockRequest(request.url)
      @_networkTraffic[request.id].blocked = true
      @_blockedUrls.push request.url unless request.url in @_blockedUrls

      net.abort()
    else
      @lastRequestId = request.id

      if @normalizeURL(request.url) == @redirectURL
        @removeTempHeadersForRedirect()
        @redirectURL = null
        @requestId   = request.id

      @_requestedResources[request.id] = request.url
    return true

  onResourceReceivedNative: (response) ->
    @_networkTraffic[response.id]?.responseParts.push(response)

    if response.stage == 'end'
      delete @_requestedResources[response.id]

    if @requestId == response.id
      if response.redirectURL
        @removeTempHeadersForRedirect()
        @redirectURL = @normalizeURL(response.redirectURL)
      else
        @statusCode = response.status
        @_responseHeaders = response.headers
    return true

  onResourceErrorNative: (errorResponse) ->
    @_networkTraffic[errorResponse.id]?.error = errorResponse
    delete @_requestedResources[errorResponse.id]
    return true

  onResourceTimeoutNative: (request) ->
    console.log "Resource request timed out for #{request.url}"

  injectAgent: ->
    if @native().evaluate(-> typeof __poltergeist) == "undefined"
      @native().injectJs "#{phantom.libraryPath}/agent.js"
      @native().injectJs extension for extension in WebPage.EXTENSIONS
      return true
    return false

  injectExtension: (file) ->
    WebPage.EXTENSIONS.push file
    @native().injectJs file

  native: ->
    if @closed
      throw new Poltergeist.NoSuchWindowError
    else
      @_native

  windowName: ->
    @native().windowName

  keyCode: (name) ->
    name = "Control" if name == "Ctrl"
    @native().event.key[name]

  keyModifierCode: (names) ->
    modifiers = @native().event.modifier
    names.split(',').map((name) -> modifiers[name]).reduce((n1,n2) -> n1 | n2)

  keyModifierKeys: (names) ->
    for name in names.split(',') when name isnt 'keypad'
      @keyCode(name.charAt(0).toUpperCase() + name.substring(1))

  _waitState_until: (states, callback, timeout, timeout_callback) ->
    if (@state in states)
      callback.call(this, @state)
    else
      if new Date().getTime() > timeout
        timeout_callback.call(this)
      else
        setTimeout (=> @_waitState_until(states, callback, timeout, timeout_callback)), 100

  waitState: (states, callback, max_wait=0, timeout_callback) ->
    # callback and timeout_callback will be called with this == the current page
    states = [].concat(states)
    if @state in states
      callback.call(this, @state)
    else
      if max_wait != 0
        timeout = new Date().getTime() + (max_wait*1000)
        setTimeout (=> @_waitState_until(states, callback, timeout, timeout_callback)), 100
      else
        setTimeout (=> @waitState(states, callback)), 100

  setHttpAuth: (user, password) ->
    @native().settings.userName = user
    @native().settings.password = password
    return true

  networkTraffic: (type) ->
    switch type
      when 'all'
        request for own id, request of @_networkTraffic
      when 'blocked'
        request for own id, request of @_networkTraffic when request.blocked
      else
        request for own id, request of @_networkTraffic when not request.blocked

  clearNetworkTraffic: ->
    @_networkTraffic = {}
    return true

  blockedUrls: ->
    @_blockedUrls

  clearBlockedUrls: ->
    @_blockedUrls = []
    return true

  openResourceRequests: ->
    url for own id, url of @_requestedResources

  content: ->
    @native().frameContent

  title: ->
    @native().title

  frameTitle: ->
    @native().frameTitle

  currentUrl: ->
    # native url doesn't return anything when about:blank
    # in that case get the frame url which will be main window
    @native().url || @runCommand('frameUrl')

  frameUrl: ->
    if phantom.version.major > 2 || (phantom.version.major == 2 && phantom.version.minor >= 1)
      @native().frameUrl || @runCommand('frameUrl')
    else
      @runCommand('frameUrl')

  frameUrlFor: (frameNameOrId) ->
    query = (frameNameOrId) ->
      document.querySelector("iframe[name='#{frameNameOrId}'], iframe[id='#{frameNameOrId}']")?.src
    @evaluate(query, frameNameOrId)

  clearErrors: ->
    @errors = []
    return true

  responseHeaders: ->
    headers = {}
    @_responseHeaders.forEach (item) ->
      headers[item.name] = item.value
    headers

  cookies: ->
    @native().cookies

  deleteCookie: (name) ->
    @native().deleteCookie(name)

  viewportSize: ->
    @native().viewportSize

  setViewportSize: (size) ->
    @native().viewportSize = size

  setZoomFactor: (zoom_factor) ->
    @native().zoomFactor = zoom_factor

  setPaperSize: (size) ->
    @native().paperSize = size

  scrollPosition: ->
    @native().scrollPosition

  setScrollPosition: (pos) ->
    @native().scrollPosition = pos

  clipRect: ->
    @native().clipRect

  setClipRect: (rect) ->
    @native().clipRect = rect

  elementBounds: (selector) ->
    @native().evaluate(
      (selector) ->
        document.querySelector(selector).getBoundingClientRect()
      , selector
    )

  getUserAgent: ->
    @native().settings.userAgent

  setUserAgent: (userAgent) ->
    @native().settings.userAgent = userAgent

  getCustomHeaders: ->
    @native().customHeaders

  getPermanentCustomHeaders: ->
    allHeaders = @getCustomHeaders()
    for name, value of @_tempHeaders
      delete allHeaders[name]
    for name, value of @_tempHeadersToRemoveOnRedirect
      delete allHeaders[name]
    allHeaders

  setCustomHeaders: (headers) ->
    @native().customHeaders = headers

  addTempHeader: (header) ->
    @_tempHeaders[name] = value for name, value of header
    @_tempHeaders

  addTempHeaderToRemoveOnRedirect: (header) ->
    for name, value of header
      @_tempHeadersToRemoveOnRedirect[name] = value
    @_tempHeadersToRemoveOnRedirect

  removeTempHeadersForRedirect: ->
    allHeaders = @getCustomHeaders()
    for name, value of @_tempHeadersToRemoveOnRedirect
      delete allHeaders[name]
    @setCustomHeaders(allHeaders)

  removeTempHeaders: ->
    allHeaders = @getCustomHeaders()
    delete allHeaders[name] for namve, value of @_temptHeaders
    @setCustomHeaders(allHeaders)

  pushFrame: (name) ->
    return true if @native().switchToFrame(name)

    # if switch by name fails - find index and try again
    frame_no = @native().evaluate(
      (frame_name) ->
        frames = document.querySelectorAll("iframe, frame")
        (idx for f, idx in frames when f?['name'] == frame_name or f?['id'] == frame_name)[0]
      , name)
    frame_no? and @native().switchToFrame(frame_no)

  popFrame: (pop_all = false)->
    if pop_all
      @native().switchToMainFrame()
    else
      @native().switchToParentFrame()

  dimensions: ->
    scroll   = @scrollPosition()
    viewport = @viewportSize()

    top:    scroll.top,  bottom: scroll.top  + viewport.height,
    left:   scroll.left, right:  scroll.left + viewport.width,
    viewport: viewport
    document: @documentSize()

  # A work around for http://code.google.com/p/phantomjs/issues/detail?id=277
  validatedDimensions: ->
    dimensions = @dimensions()
    document   = dimensions.document

    if dimensions.right > document.width
      dimensions.left  = Math.max(0, dimensions.left - (dimensions.right - document.width))
      dimensions.right = document.width

    if dimensions.bottom > document.height
      dimensions.top    = Math.max(0, dimensions.top - (dimensions.bottom - document.height))
      dimensions.bottom = document.height

    @setScrollPosition(left: dimensions.left, top: dimensions.top)

    dimensions

  get: (id) ->
    new Poltergeist.Node(this, id)

  # Before each mouse event we make sure that the mouse is moved to where the
  # event will take place. This deals with e.g. :hover changes.
  mouseEvent: (name, x, y, button = 'left', modifiers = 0) ->
    @sendEvent('mousemove', x, y)
    @sendEvent(name, x, y, button, modifiers)

  evaluate: (fn, args...) ->
    @injectAgent()
    @native().evaluate("function() {
      var page_id = arguments[0];
      var args = [];

      for(var i=1; i < arguments.length; i++){
        if ((typeof(arguments[i]) == 'object') && (typeof(arguments[i]['ELEMENT']) == 'object')){
          args.push(window.__poltergeist.get(arguments[i]['ELEMENT']['id']).element);
        } else {
          args.push(arguments[i])
        }
      }
      var _result = #{@stringifyCall(fn, "args")};
      return window.__poltergeist.wrapResults(_result, page_id); }", @id, args...)

  evaluate_async: (fn, callback, args...) ->
    command_id = ++@_asyncEvaluationId
    cb = callback
    @injectAgent()
    @native().evaluate("function(){
      var page_id = arguments[0];
      var args = [];
      for(var i=1; i < arguments.length; i++){
        if ((typeof(arguments[i]) == 'object') && (typeof(arguments[i]['ELEMENT']) == 'object')){
          args.push(window.__poltergeist.get(arguments[i]['ELEMENT']['id']).element);
        } else {
          args.push(arguments[i])
        }
      }
      args.push(function(result){
        result = window.__poltergeist.wrapResults(result, page_id);
        window.callPhantom( { command_id: #{command_id}, command_result: result } );
      });
      #{@stringifyCall(fn, "args")};
      return}", @id, args...)

    setTimeout( =>
      @_checkForAsyncResult(command_id, cb)
    , 10)
    return

  execute: (fn, args...) ->
    @injectAgent()
    @native().evaluate("function() {
      for(var i=0; i < arguments.length; i++){
        if ((typeof(arguments[i]) == 'object') && (typeof(arguments[i]['ELEMENT']) == 'object')){
          arguments[i] = window.__poltergeist.get(arguments[i]['ELEMENT']['id']).element;
        }
      }
      #{@stringifyCall(fn)} }", args...)

  stringifyCall: (fn, args_name = "arguments") ->
    "(#{fn.toString()}).apply(this, #{args_name})"

  bindCallback: (name) ->
    @native()[name] = =>
      result = @[name + 'Native'].apply(@, arguments) if @[name + 'Native']? # For internal callbacks
      @[name].apply(@, arguments) if result != false && @[name]? # For externally set callbacks
    return true

  # Any error raised here or inside the evaluate will get reported to
  # phantom.onError. If result is null, that means there was an error
  # inside the agent.
  runCommand: (name, args) ->
    result = @evaluate(
      (name, args) -> __poltergeist.externalCall(name, args),
      name, args
    )

    if result?.error?
      switch result.error.message
        when 'PoltergeistAgent.ObsoleteNode'
          throw new Poltergeist.ObsoleteNode
        when 'PoltergeistAgent.InvalidSelector'
          [method, selector] = args
          throw new Poltergeist.InvalidSelector(method, selector)
        else
          throw new Poltergeist.BrowserError(result.error.message, result.error.stack)
    else
      result?.value

  canGoBack: ->
    @native().canGoBack

  canGoForward: ->
    @native().canGoForward

  normalizeURL: (url) ->
    parser = document.createElement('a')
    parser.href = url
    return parser.href

  clearMemoryCache: ->
    @native().clearMemoryCache()

  _checkForAsyncResult: (command_id, callback)=>
    if @_asyncResults.hasOwnProperty(command_id)
      callback(@_asyncResults[command_id])
      delete @_asyncResults[command_id]
    else
      setTimeout(=>
        @_checkForAsyncResult(command_id, callback)
      , 50)
    return

  _blockRequest: (url) ->
    useWhitelist = @urlWhitelist.length > 0

    whitelisted = @urlWhitelist.some (whitelisted_regex) ->
      whitelisted_regex.test url

    blacklisted = @urlBlacklist.some (blacklisted_regex) ->
      blacklisted_regex.test url

    if useWhitelist && !whitelisted
      return true

    if blacklisted
      return true

    false
