#= require ./location
#= require ./browser_adapter
#= require ./history
#= require ./view
#= require ./scroll_manager
#= require ./cache
#= require ./visit

class Turbolinks.Controller
  constructor: ->
    @history = new Turbolinks.History this
    @view = new Turbolinks.View this
    @scrollManager = new Turbolinks.ScrollManager this
    @restorationData = {}
    @clearCache()

  start: ->
    unless @started
      addEventListener("click", @clickCaptured, true)
      @startHistory()
      if document.readyState is "loading"
        addEventListener("DOMContentLoaded", @pageLoaded, false)
      else
        @pageLoaded()
      @scrollManager.start()
      @started = true
      @enabled = true

  disable: ->
    @enabled = false

  stop: ->
    if @started
      removeEventListener("click", @clickCaptured, true)
      removeEventListener("DOMContentLoaded", @pageLoaded, false)
      @scrollManager.stop()
      @stopHistory()
      @started = false

  clearCache: ->
    @cache = new Turbolinks.Cache 10

  visit: (location, options = {}) ->
    location = Turbolinks.Location.wrap(location)
    if @applicationAllowsVisitingLocation(location)
      if @locationIsVisitable(location)
        action = options.action ? "advance"
        @adapter.visitProposedToLocationWithAction(location, action)
      else
        window.location = location

  startVisitToLocationWithAction: (location, action, restorationIdentifier) ->
    if Turbolinks.supported
      restorationData = @getRestorationDataForIdentifier(restorationIdentifier)
      @startVisit(location, action, {restorationData})
    else
      window.location = location

  # History

  startHistory: ->
    @location = Turbolinks.Location.wrap(window.location)
    @restorationIdentifier = Turbolinks.uuid()
    @history.start()
    @history.replace(@location, @restorationIdentifier)

  stopHistory: ->
    @history.stop()

  pushHistoryWithLocationAndRestorationIdentifier: (location, @restorationIdentifier) ->
    @location = Turbolinks.Location.wrap(location)
    @history.push(@location, @restorationIdentifier)

  replaceHistoryWithLocationAndRestorationIdentifier: (location, @restorationIdentifier) ->
    @location = Turbolinks.Location.wrap(location)
    @history.replace(@location, @restorationIdentifier)

  # History delegate

  historyPoppedToLocationWithRestorationIdentifier: (location, @restorationIdentifier) ->
    if @enabled
      restorationData = @getRestorationDataForIdentifier(@restorationIdentifier)
      @startVisit(location, "restore", {@restorationIdentifier, restorationData, historyChanged: true})
      @location = Turbolinks.Location.wrap(location)
    else
      @adapter.pageInvalidated()

  # Snapshot cache

  getCachedSnapshotForLocation: (location) ->
    @cache.get(location)

  shouldCacheSnapshot: ->
    @view.getCacheControlValue() isnt "no-cache"

  cacheSnapshot: ->
    if @shouldCacheSnapshot()
      @notifyApplicationBeforeCachingSnapshot()
      snapshot = @view.getSnapshot(clone: true)
      @cache.put(@lastRenderedLocation, snapshot)

  # Scrolling

  scrollToAnchor: (anchor) ->
    if element = document.getElementById(anchor)
      @scrollToElement(element)
    else
      @scrollToPosition(x: 0, y: 0)

  scrollToElement: (element) ->
    @scrollManager.scrollToElement(element)

  scrollToPosition: (position) ->
    @scrollManager.scrollToPosition(position)

  # Scroll manager delegate

  scrollPositionChanged: (scrollPosition) ->
    restorationData = @getCurrentRestorationData()
    restorationData.scrollPosition = scrollPosition

  # View

  render: (options, callback) ->
    @view.render(options, callback)

  viewInvalidated: ->
    @adapter.pageInvalidated()

  viewWillRender: (newBody) ->
    @notifyApplicationBeforeRender(newBody)

  viewRendered: ->
    @lastRenderedLocation = @currentVisit.location
    @notifyApplicationAfterRender()

  # Event handlers

  pageLoaded: =>
    @lastRenderedLocation = @location
    @notifyApplicationAfterPageLoad()

  clickCaptured: =>
    removeEventListener("click", @clickBubbled, false)
    addEventListener("click", @clickBubbled, false)

  clickBubbled: (event) =>
    if @enabled and @clickEventIsSignificant(event)
      if link = @getVisitableLinkForNode(event.target)
        if location = @getVisitableLocationForLink(link)
          if @applicationAllowsFollowingLinkToLocation(link, location)
            event.preventDefault()
            action = @getActionForLink(link)
            @visit(location, {action})

  # Application events

  applicationAllowsFollowingLinkToLocation: (link, location) ->
    event = @notifyApplicationAfterClickingLinkToLocation(link, location)
    not event.defaultPrevented

  applicationAllowsVisitingLocation: (location) ->
    event = @notifyApplicationBeforeVisitingLocation(location)
    not event.defaultPrevented

  notifyApplicationAfterClickingLinkToLocation: (link, location) ->
    Turbolinks.dispatch("turbolinks:click", target: link, data: { url: location.absoluteURL }, cancelable: true)

  notifyApplicationBeforeVisitingLocation: (location) ->
    Turbolinks.dispatch("turbolinks:before-visit", data: { url: location.absoluteURL }, cancelable: true)

  notifyApplicationAfterVisitingLocation: (location) ->
    Turbolinks.dispatch("turbolinks:visit", data: { url: location.absoluteURL })

  notifyApplicationBeforeCachingSnapshot: ->
    Turbolinks.dispatch("turbolinks:before-cache")

  notifyApplicationBeforeRender: (newBody) ->
    Turbolinks.dispatch("turbolinks:before-render", data: {newBody})

  notifyApplicationAfterRender: ->
    Turbolinks.dispatch("turbolinks:render")

  notifyApplicationAfterPageLoad: (timing = {}) ->
    Turbolinks.dispatch("turbolinks:load", data: { url: @location.absoluteURL, timing })

  # Private

  startVisit: (location, action, properties) ->
    @currentVisit?.cancel()
    @currentVisit = @createVisit(location, action, properties)
    @currentVisit.start()
    @notifyApplicationAfterVisitingLocation(location)

  createVisit: (location, action, {restorationIdentifier, restorationData, historyChanged} = {}) ->
    visit = new Turbolinks.Visit this, location, action
    visit.restorationIdentifier = restorationIdentifier ? Turbolinks.uuid()
    visit.restorationData = Turbolinks.copyObject(restorationData)
    visit.historyChanged = historyChanged
    visit.referrer = @location
    visit

  visitCompleted: (visit) ->
    @notifyApplicationAfterPageLoad(visit.getTimingMetrics())

  clickEventIsSignificant: (event) ->
    not (
      event.defaultPrevented or
      event.target.isContentEditable or
      event.which > 1 or
      event.altKey or
      event.ctrlKey or
      event.metaKey or
      event.shiftKey
    )

  getVisitableLinkForNode: (node) ->
    if @nodeIsVisitable(node)
      Turbolinks.closest(node, "a[href]:not([target])")

  getVisitableLocationForLink: (link) ->
    location = new Turbolinks.Location link.href
    location if @locationIsVisitable(location)

  getActionForLink: (link) ->
    link.getAttribute("data-turbolinks-action") ? "advance"

  nodeIsVisitable: (node) ->
    if container = Turbolinks.closest(node, "[data-turbolinks]")
      container.getAttribute("data-turbolinks") isnt "false"
    else
      true

  locationIsVisitable: (location) ->
    location.isPrefixedBy(@view.getRootLocation()) and location.isHTML()

  getCurrentRestorationData: ->
    @getRestorationDataForIdentifier(@restorationIdentifier)

  getRestorationDataForIdentifier: (identifier) ->
    @restorationData[identifier] ?= {}

do ->
  Turbolinks.controller = controller = new Turbolinks.Controller
  controller.adapter = new Turbolinks.BrowserAdapter(controller)
  controller.start()
