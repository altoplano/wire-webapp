#
# Wire
# Copyright (C) 2016 Wire Swiss GmbH
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see http://www.gnu.org/licenses/.
#

window.z ?= {}
z.ViewModel ?= {}

###
Message list rendering view model.

@todo Get rid of the $('.conversation') opacity
@todo Get rid of the participants dependencies whenever bubble implementation has changed
@todo Remove all jquery selectors
###
class z.ViewModel.MessageListViewModel
  constructor: (element_id, @conversation_repository, @user_repository) ->
    @logger = new z.util.Logger 'z.ViewModel.MessageListViewModel', z.config.LOGGER.OPTIONS

    @conversation = ko.observable new z.entity.Conversation()
    @center_messages = ko.pureComputed =>
      return not @conversation().has_further_messages() and @conversation().messages_visible().length is 1 and @conversation().messages_visible()[0]?.is_connection?()

    @conversation_is_changing = false

    # store last read to show until user switches conversation
    @conversation_last_read_timestamp = ko.observable undefined

    # store conversation to mark as read when browser gets focus
    @mark_as_read_on_focus = undefined

    # can we used to prevent scroll handler from being executed (e.g. when using scrollTop())
    @capture_scrolling_event = false

    # store message subscription id
    @messages_subscription = undefined

    # Last open bubble
    @participant_bubble = undefined
    @participant_bubble_last_id = undefined

    @viewport_changed = ko.observable false
    @viewport_changed.extend rateLimit: 100

    @recalculate_timeout = undefined

    @should_scroll_to_bottom = true
    @ephemeral_timers = {}

    # Check if the message container is to small and then pull new events
    @on_mouse_wheel = _.throttle (e) =>
      is_not_scrollable = not $(e.currentTarget).is_scrollable()
      is_scrolling_up = e.deltaY > 0
      if is_not_scrollable and is_scrolling_up
        @_pull_events()
    , 200

    @on_scroll = _.throttle (data, e) =>
      return if not @capture_scrolling_event

      @viewport_changed not @viewport_changed()

      element = $ e.currentTarget

      # On some HDPI screen scrollTop returns a floating point number instead of an integer
      # https://github.com/jquery/api.jquery.com/issues/608
      scroll_position = Math.ceil element.scrollTop()
      scroll_end = element.scroll_end()
      scrolled_bottom = false

      if scroll_position is 0
        @_pull_events()

      if scroll_position >= scroll_end
        scrolled_bottom = true

        if document.hasFocus()
          @conversation_repository.mark_as_read @conversation()
        else
          @mark_as_read_on_focus = @conversation()

      @should_scroll_to_bottom = scroll_position > scroll_end - z.config.SCROLL_TO_LAST_MESSAGE_THRESHOLD

      amplify.publish z.event.WebApp.LIST.SCROLL, scrolled_bottom
    , 100

    $(window)
    .on 'resize', =>
      @viewport_changed not @viewport_changed()
    .on 'focus', =>
      if @mark_as_read_on_focus?
        window.setTimeout =>
          @conversation_repository.mark_as_read @mark_as_read_on_focus
          @mark_as_read_on_focus = undefined
        , 1000

    amplify.subscribe z.event.WebApp.CONVERSATION.PEOPLE.HIDE, @hide_bubble
    amplify.subscribe z.event.WebApp.CONTEXT_MENU, @on_context_menu_action

  ###
  Remove all subscriptions and reset states.
  @param conversation_et [z.entity.Conversation] Conversation entity to change to
  ###
  release_conversation: (conversation_et) =>
    conversation_et?.release()
    @messages_subscription?.dispose()
    @capture_scrolling_event = false
    @conversation_last_read_timestamp false

  ###
  Change conversation.
  @param conversation_et [z.entity.Conversation] Conversation entity to change to
  @param callback [Function] Executed when all events are loaded an conversation is ready to be displayed
  ###
  change_conversation: (conversation_et, callback) =>
    @conversation_is_changing = true

    # clean up old conversation
    @release_conversation @conversation() if @conversation()

    # update new conversation
    @conversation conversation_et

    # keep last read timestamp to render unread when entering conversation
    if @conversation().number_of_unread_messages() > 0
      @conversation_last_read_timestamp @conversation().last_read_timestamp()

    if not conversation_et.is_loaded()
      @conversation_repository.update_participating_user_ets conversation_et, (conversation_et) =>

        # release any event that are not unread
        conversation_et.release()

        @conversation_repository.get_events conversation_et
        .then =>
          @_set_conversation conversation_et, callback
          conversation_et.is_loaded true
    else
      @_set_conversation conversation_et, callback

  ###
  Sets the conversation and waits for further processing until knockout has rendered the messages.
  @param conversation_et [z.entity.Conversation] Conversation entity to set
  @param callback [Function] Executed when message list is ready to fade in
  ###
  _set_conversation: (conversation_et, callback) =>
    # hide conversation until everything is processed
    $('.conversation').css opacity: 0

    @conversation_is_changing = false

    if @conversation().messages_visible().length is 0
      # return immediately if nothing to render
      @_initial_rendering conversation_et, callback
    else
      window.setTimeout =>
        @_initial_rendering conversation_et, callback
      , 200

  ###
  Registers for mouse wheel events and incoming messages.

  @note Call this once after changing conversation.
  @param conversation_et [z.entity.Conversation] Conversation entity to render
  @param callback [Function] Executed when message list is ready to fade in
  ###
  _initial_rendering: (conversation_et, callback) =>
    messages_container = $('.messages-wrap')
    messages_container.on 'mousewheel', @on_mouse_wheel

    window.requestAnimationFrame =>
      is_current_conversation = conversation_et is @conversation()
      if not is_current_conversation
        @logger.log @logger.levels.INFO, 'Skipped loading conversation', conversation_et.display_name()
        return

      # reset scroll position
      messages_container.scrollTop 0

      @capture_scrolling_event = true

      if not messages_container.is_scrollable()
        @conversation_repository.mark_as_read conversation_et
      else
        unread_message = $ '.message-timestamp-unread'
        if unread_message.length > 0
          messages_container.scroll_by unread_message.parent().parent().position().top
        else
          messages_container.scroll_to_bottom()
      $('.conversation').css opacity: 1

      # subscribe for incoming messages
      @messages_subscription = conversation_et.messages_visible.subscribe @_on_message_add, null, 'arrayChange'
      @_subscribe_to_iframe_clicks()
      callback?()

  ###
  Checks how to scroll message list and if conversation should be marked as unread.

  @param message [Array] Array of message entities
  ###
  _on_message_add: (messages) =>
    messages_container = $('.messages-wrap')
    last_item = messages[messages.length - 1]
    last_message = last_item.value

    # we are only interested in items that were added
    if last_item.status isnt 'added'
      return

    # message was prepended
    if last_message?.timestamp isnt @conversation().last_event_timestamp()
      return

    # scroll to bottom if self user send the message
    if last_message?.from is @user_repository.self().id
      window.requestAnimationFrame -> messages_container.scroll_to_bottom()
      return

    # scroll to the end of the list if we are under a certain threshold
    if @should_scroll_to_bottom
      @conversation_repository.mark_as_read @conversation() if document.hasFocus()
      window.requestAnimationFrame -> messages_container.scroll_to_bottom()

    # mark as read when conversation is not scrollable
    is_scrollable = messages_container.is_scrollable()
    is_browser_has_focus = document.hasFocus()
    if not is_scrollable
      if is_browser_has_focus
        @conversation_repository.mark_as_read @conversation()
      else
        @mark_as_read_on_focus = @conversation()

  # Get previous messages from the backend.
  _pull_events: =>
    if not @conversation().is_pending() and @conversation().has_further_messages()
      inner_container = $('.messages-wrap').children()[0]
      old_list_height = inner_container.scrollHeight

      @capture_scrolling_event = false
      @conversation_repository.get_events @conversation()
      .then =>
        new_list_height = inner_container.scrollHeight
        $('.messages-wrap').scrollTop new_list_height - old_list_height
        @capture_scrolling_event = true

  scroll_height: (change_in_height) ->
    $('.messages-wrap').scroll_by change_in_height

  ###
  Triggered when user clicks on an avatar in the message list.
  @param user_et [z.entity.User] User entity of the selected user
  @param message [DOMElement] Selected DOMElement
  ###
  on_message_user_click: (user_et, element) =>
    BUBBLE_HEIGHT = 440
    MESSAGE_LIST_MIN_HEIGHT = 400
    list_height = $('.message-list').height()
    element_rect = element.getBoundingClientRect()
    element_distance_top = element_rect.top
    element_distance_bottom = list_height - element_rect.top - element_rect.height
    largest_distance = Math.max element_distance_top, element_distance_bottom
    difference = BUBBLE_HEIGHT - largest_distance

    create_bubble = (element_id) =>
      wire.app.view.content.participants.reset_view()
      @participant_bubble_last_id = element_id
      @participant_bubble = new zeta.webapp.module.Bubble
        host_selector: "##{element_id}"
        scroll_selector: '.messages-wrap'
        modal: true
        on_show: ->
          amplify.publish z.event.WebApp.PEOPLE.SHOW, user_et
        on_hide: =>
          @participant_bubble = undefined
          @participant_bubble_last_id = undefined
      @participant_bubble.toggle()

    show_bubble = =>
      wire.app.view.content.participants.confirm_dialog?.destroy()
      # we clicked on the same bubble
      if @participant_bubble and @participant_bubble_last_id is element.id
        @participant_bubble.toggle()
        return

      # dismiss old bubble and wait with creating the new one when another bubble is open
      if @participant_bubble or wire.app.view.content.participants.participants_bubble?.is_visible()
        @participant_bubble?.hide()
        window.setTimeout ->
          create_bubble(element.id)
        , 550
      else
        create_bubble(element.id)

    if difference > 0 and list_height > MESSAGE_LIST_MIN_HEIGHT
      if largest_distance is element_distance_top
        @scroll_by -difference, show_bubble
      else
        @scroll_by difference, show_bubble
    else
      show_bubble()

  ###
  Triggered when user clicks on the session reset link in a decrypt error message.
  @param message_et [z.entity.DecryptErrorMessage] Decrypt error message
  ###
  on_session_reset_click: (message_et) =>
    reset_progress = ->
      window.setTimeout ->
        message_et.is_resetting_session false
        amplify.publish z.event.WebApp.WARNING.MODAL, z.ViewModel.ModalType.SESSION_RESET
      , 550

    message_et.is_resetting_session true
    @conversation_repository.reset_session message_et.from, message_et.client_id, @conversation().id
    .then -> reset_progress()
    .catch -> reset_progress()

  # Subscribes to iFrame click events.
  _subscribe_to_iframe_clicks: ->
    $('iframe.soundcloud').iframeTracker blurCallback: ->
      amplify.publish z.event.WebApp.ANALYTICS.EVENT, z.tracking.SessionEventName.INTEGER.SOUNDCLOUD_CONTENT_CLICKED

    $('iframe.youtube').iframeTracker blurCallback: ->
      amplify.publish z.event.WebApp.ANALYTICS.EVENT, z.tracking.SessionEventName.INTEGER.YOUTUBE_CONTENT_CLICKED

  # Hides participant bubble.
  hide_bubble: =>
    @participant_bubble?.hide()

  ###
  Scrolls whole message list by given distance.

  @note Scrolling is animated with jQuery
  @param distance [Number] Distance by which the container is shifted
  @param callback [Function] Executed when scroll animation is finished
  ###
  scroll_by: (distance, callback) ->
    current_scroll = $('.messages-wrap').scrollTop()
    new_scroll = current_scroll + distance
    $('.messages-wrap').animate {scrollTop: new_scroll}, 300, callback

  ###
  Gets CSS class that will be applied to the message div in order to style.
  @param message [z.entity.Message] Message entity for generating css class
  @return [String] CSS class that is applied to the element
  ###
  get_css_class: (message) ->
    switch message.super_type
      when z.message.SuperType.CALL
        return 'message-system message-call'
      when z.message.SuperType.CONTENT
        return 'message-normal'
      when z.message.SuperType.MEMBER
        return 'message message-system message-member'
      when z.message.SuperType.PING
        return 'message-ping'
      when z.message.SuperType.SYSTEM
        if message.system_message_type is z.message.SystemMessageType.CONVERSATION_RENAME
          return 'message-system message-rename'
      when z.message.SuperType.UNABLE_TO_DECRYPT
        return 'message-system'

  ###
  Create context menu entries for given message
  @param message_et [z.entity.Message]
  ###
  get_context_menu_entries: (message_et) =>
    entries = []

    @_track_context_menu message_et

    if message_et.has_asset() and not message_et.is_ephemeral()
      entries.push {label: z.string.conversation_context_menu_download, action: 'download'}

    if message_et.is_reactable() and not @conversation().removed_from_conversation()
      if message_et.is_liked()
        entries.push {label: z.string.conversation_context_menu_unlike, action: 'react'}
      else
        entries.push {label: z.string.conversation_context_menu_like, action: 'react'}

    if message_et.is_editable() and not @conversation().removed_from_conversation()
      entries.push {label: z.string.conversation_context_menu_edit, action: 'edit'}

    if message_et.is_deletable()
      entries.push {label: z.string.conversation_context_menu_delete, action: 'delete'}

    if message_et.user().is_me and not @conversation().removed_from_conversation() and message_et.status() isnt z.message.StatusType.SENDING
      entries.push {label: z.string.conversation_context_menu_delete_everyone, action: 'delete-everyone'}

    return entries

  ###
  Track context menu click
  @param message_et [z.entity.Message]
  ###
  _track_context_menu: (message_et) =>
    amplify.publish z.event.WebApp.ANALYTICS.EVENT, z.tracking.EventName.CONVERSATION.SELECTED_MESSAGE,
      context: 'single'
      conversation_type: z.tracking.helpers.get_conversation_type @conversation()
      type: z.tracking.helpers.get_message_type message_et

  ###
  Click on context menu entry
  @param tag [String] associated tag
  @param action [String] action that was triggered
  @param data [Object] optional data
  ###
  on_context_menu_action: (tag, action, data) =>
    return if tag isnt 'message'

    message_et = @conversation().get_message_by_id data

    switch action
      when 'delete'
        amplify.publish z.event.WebApp.WARNING.MODAL, z.ViewModel.ModalType.DELETE_MESSAGE,
          action: => @conversation_repository.delete_message @conversation(), message_et
      when 'delete-everyone'
        amplify.publish z.event.WebApp.WARNING.MODAL, z.ViewModel.ModalType.DELETE_EVERYONE_MESSAGE,
          action: => @conversation_repository.delete_message_everyone @conversation(), message_et
      when 'download'
        message_et?.get_first_asset()?.download()
      when 'edit'
        amplify.publish z.event.WebApp.CONVERSATION.MESSAGE.EDIT, message_et
      when 'react'
        @click_on_like message_et, false

  ###
  Shows detail image view.
  @param asset_et [z.assets.Asset] Asset to be displayed
  @param event [UIEvent] Actual scroll event
  ###
  show_detail: (asset_et, event) ->
    target_element = $(event.currentTarget)
    return if target_element.hasClass 'bg-color-ephemeral'
    return if target_element.hasClass 'image-loading'
    amplify.publish z.event.WebApp.CONVERSATION.DETAIL_VIEW.SHOW, target_element.find('img')[0].src

  get_timestamp_class: (message_et) ->
    last_message = @conversation().get_previous_message message_et
    return if not last_message?

    if message_et.is_call()
      return ''

    if last_message.timestamp is @conversation_last_read_timestamp()
      return 'message-timestamp-visible message-timestamp-unread'

    last = moment last_message.timestamp
    current = moment message_et.timestamp

    if not last.isSame current, 'day'
      return 'message-timestamp-visible message-timestamp-day'

    if current.diff(last, 'minutes') > 60
      return 'message-timestamp-visible'

  ###
  Checks its older neighbor in order to see if the avatar should be rendered or not
  @param message_et [z.entity.Message]
  ###
  should_hide_user_avatar: (message_et) ->
    last_message = @conversation().get_previous_message message_et

    # TODO avoid double check
    if @get_timestamp_class message_et
      return false

    if message_et.is_content() and message_et.replacing_message_id
      return false

    if last_message?.is_content() and last_message?.user().id is message_et.user().id
      return true

    return false

  ###
  Checks if the given message is the last delivered one
  @param message_et [z.entity.Message]
  ###
  is_last_delivered_message: (message_et) ->
    return @conversation().get_last_delivered_message() is message_et

  click_on_cancel_request: (message_et) =>
    next_conversation_et = @conversation_repository.get_next_conversation @conversation_repository.active_conversation()
    @user_repository.cancel_connection_request message_et.other_user(), next_conversation_et

  click_on_like: (message_et, button = true) =>
    return if @conversation().removed_from_conversation()

    reaction = if message_et.is_liked() then z.message.ReactionType.NONE else z.message.ReactionType.LIKE
    message_et.is_liked not message_et.is_liked()

    window.setTimeout =>
      @conversation_repository.send_reaction @conversation(), message_et, reaction
      @_track_reaction @conversation(), message_et, reaction, button
    , 50

  ###
  Track reaction action.

  @param conversation_et [z.entity.Conversation]
  @param message_et [z.entity.Message]
  @param reaction [z.message.ReactionType]
  @param button [Boolean]
  ###
  _track_reaction: (conversation_et, message_et, reaction, button = true) ->
    amplify.publish z.event.WebApp.ANALYTICS.EVENT, z.tracking.EventName.CONVERSATION.REACTED_TO_MESSAGE,
      conversation_type: z.tracking.helpers.get_conversation_type conversation_et
      action: if reaction then 'like' else 'unlike'
      with_bot: conversation_et.is_with_bot()
      method: if button then 'button' else 'menu'
      user: if message_et.user().is_me then 'sender' else 'receiver'
      type: z.tracking.helpers.get_message_type message_et
      reacted_to_last_message: conversation_et.get_last_message() is message_et

  ###
  Message appeared in viewport.
  @param message_et [z.entity.Message]
  ###
  message_in_viewport: (message_et) =>
    return if not message_et.is_ephemeral()

    set_ephemeral_timer = =>
      @conversation_repository.get_ephemeral_timer message_et
      .then (millis) => @start_ephemeral_timer message_et, millis if millis?

    if document.hasFocus()
      set_ephemeral_timer()
    else
      start_timer_on_focus = @conversation.id

      $(window).one 'focus', =>
        set_ephemeral_timer() if start_timer_on_focus is @conversation.id

  ###
  Start ephemeral timeout.

  @param message_et [z.entity.Message]
  @param millis [Number]
  ###
  start_ephemeral_timer: (message_et, millis) ->
    return if @ephemeral_timers[message_et.id]

    conversation_et = @conversation()
    @ephemeral_timers[message_et.id] = window.setTimeout (=>
      @conversation_repository.timeout_ephemeral_message conversation_et, message_et
    ), millis
