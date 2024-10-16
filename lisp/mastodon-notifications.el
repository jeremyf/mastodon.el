;;; mastodon-notifications.el --- Notification functions for mastodon.el -*- lexical-binding: t -*-

;; Copyright (C) 2017-2019 Johnson Denen
;; Copyright (C) 2020-2022 Marty Hiatt
;; Author: Johnson Denen <johnson.denen@gmail.com>
;;         Marty Hiatt <martianhiatus@riseup.net>
;; Maintainer: Marty Hiatt <martianhiatus@riseup.net>
;; Homepage: https://codeberg.org/martianh/mastodon.el

;; This file is not part of GNU Emacs.

;; This file is part of mastodon.el.

;; mastodon.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; mastodon.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with mastodon.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; mastodon-notification.el provides notification functions for Mastodon.

;;; Code:

(eval-when-compile (require 'subr-x))
(require 'cl-lib)

(autoload 'mastodon-http--api "mastodon-http")
(autoload 'mastodon-http--get-params-async-json "mastodon-http")
(autoload 'mastodon-http--post "mastodon-http")
(autoload 'mastodon-http--triage "mastodon-http")
(autoload 'mastodon-media--inline-images "mastodon-media")
(autoload 'mastodon-tl--byline "mastodon-tl")
(autoload 'mastodon-tl--byline-author "mastodon-tl")
(autoload 'mastodon-tl--clean-tabs-and-nl "mastodon-tl")
(autoload 'mastodon-tl--content "mastodon-tl")
(autoload 'mastodon-tl--field "mastodon-tl")
(autoload 'mastodon-tl--find-property-range "mastodon-tl")
(autoload 'mastodon-tl--has-spoiler "mastodon-tl")
(autoload 'mastodon-tl--init "mastodon-tl")
(autoload 'mastodon-tl--insert-status "mastodon-tl")
(autoload 'mastodon-tl--property "mastodon-tl")
(autoload 'mastodon-tl--reload-timeline-or-profile "mastodon-tl")
(autoload 'mastodon-tl--spoiler "mastodon-tl")
(autoload 'mastodon-tl--item-id "mastodon-tl")
(autoload 'mastodon-tl--update "mastodon-tl")
(autoload 'mastodon-views--view-follow-requests "mastodon-views")
(autoload 'mastodon-tl--current-filters "mastodon-views")
(autoload 'mastodon-tl--render-text "mastodon-tl")
(autoload 'mastodon-notifications-get "mastodon")
(autoload 'mastodon-tl--byline-uname-+-handle "mastodon-tl")
(autoload 'mastodon-tl--byline-username "mastodon-tl")
(autoload 'mastodon-tl--byline-handle "mastodon-tl")
(autoload 'mastodon-http--get-json "mastodon-http")
(autoload 'mastodon-media--get-avatar-rendering "mastodon-media")
(autoload 'mastodon-tl--image-trans-check "mastodon-tl")

(defgroup mastodon-tl nil
  "Nofications in mastodon.el."
  :prefix "mastodon-notifications-"
  :group 'mastodon)

(defcustom mastodon-notifications--profile-note-in-foll-reqs t
  "If non-nil, show a user's profile note in follow request notifications."
  :type '(boolean))

(defcustom mastodon-notifications--profile-note-in-foll-reqs-max-length nil
  "The max character length for user profile note in follow requests.
Profile notes are only displayed if
`mastodon-notifications--profile-note-in-foll-reqs' is non-nil.
If unset, profile notes of any size will be displayed, which may
make them unweildy."
  :type '(integer))

(defcustom mastodon-notifications--images-in-notifs nil
  "Whether to display attached images in notifications."
  :type '(boolean))

(defvar mastodon-tl--buffer-spec)
(defvar mastodon-tl--display-media-p)
(defvar mastodon-mode-map)
(defvar mastodon-tl--fold-toots-at-length)
(defvar mastodon-tl--show-avatars)

(defvar mastodon-notifications--types-alist
  '(("follow" . mastodon-notifications--follow)
    ("favourite" . mastodon-notifications--favourite)
    ("reblog" . mastodon-notifications--reblog)
    ("mention" . mastodon-notifications--mention)
    ("poll" . mastodon-notifications--poll)
    ("follow_request" . mastodon-notifications--follow-request)
    ("status" . mastodon-notifications--status)
    ("update" . mastodon-notifications--edit))
  "Alist of notification types and their corresponding function.")

(defvar mastodon-notifications--response-alist
  '(("Followed" . "you")
    ("Favourited" . "your post")
    ("Boosted" . "your post")
    ("Mentioned" . "you")
    ("Posted a poll" . "that has now ended")
    ("Requested to follow" . "you")
    ("Posted" . "a post")
    ("Edited" . "their post"))
  "Alist of subjects for notification types.")

(defvar mastodon-notifications--map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map mastodon-mode-map)
    (define-key map (kbd "a") #'mastodon-notifications--follow-request-accept)
    (define-key map (kbd "j") #'mastodon-notifications--follow-request-reject)
    (define-key map (kbd "C-k") #'mastodon-notifications--clear-current)
    map)
  "Keymap for viewing notifications.")

(defun mastodon-notifications--byline-concat (message)
  "Add byline for TOOT with MESSAGE."
  (concat "\n " (propertize message 'face 'highlight)
          " " (cdr (assoc message mastodon-notifications--response-alist))
          "\n"))

(defun mastodon-notifications--follow-request-process (&optional reject)
  "Process the follow request at point.
With no argument, the request is accepted. Argument REJECT means
reject the request. Can be called in notifications view or in
follow-requests view."
  (if (not (mastodon-tl--find-property-range 'item-json (point)))
      (user-error "No follow request at point?")
    (let* ((item-json (mastodon-tl--property 'item-json))
           (f-reqs-view-p (string= "follow_requests"
                                   (plist-get mastodon-tl--buffer-spec 'endpoint)))
           (f-req-p (or (string= "follow_request" (alist-get 'type item-json)) ;notifs
                        f-reqs-view-p)))
      (if (not f-req-p)
          (user-error "No follow request at point?")
        (let-alist (or (alist-get 'account item-json) ;notifs
                       item-json) ;f-reqs
          (if (not .id)
              (user-error "No account result at point?")
            (let ((response
                   (mastodon-http--post
                    (mastodon-http--api
                     (format "follow_requests/%s/%s"
                             .id (if reject "reject" "authorize"))))))
              (mastodon-http--triage
               response
               (lambda (_)
                 (if f-reqs-view-p
                     (mastodon-views--view-follow-requests)
                   (mastodon-tl--reload-timeline-or-profile))
                 (message "Follow request of %s (@%s) %s!"
                          .username .acct (if reject "rejected" "accepted")))))))))))

(defun mastodon-notifications--follow-request-accept ()
  "Accept a follow request.
Can be called in notifications view or in follow-requests view."
  (interactive)
  (mastodon-notifications--follow-request-process))

(defun mastodon-notifications--follow-request-reject ()
  "Reject a follow request.
Can be called in notifications view or in follow-requests view."
  (interactive)
  (mastodon-notifications--follow-request-process :reject))

(defun mastodon-notifications--comment-note-text (str)
  "Add comment face to all text in STR with `shr-text' face only."
  (with-temp-buffer
    (insert str)
    (goto-char (point-min))
    (let (prop)
      (while (setq prop (text-property-search-forward 'face 'shr-text t))
        (add-text-properties (prop-match-beginning prop)
                             (prop-match-end prop)
                             '(face (font-lock-comment-face shr-text)))))
    (buffer-string)))

(defvar mastodon-notifications-grouped-types
  '(follow reblog favourite)
  "List of notification types for which grouping is implemented.")

(defvar mastodon-notifications--action-alist
  '((reblog . "Boosted")
    (favourite . "Favourited")
    (follow_request . "Requested to follow")
    (follow . "Followed")
    (mention . "Mentioned")
    (status . "Posted")
    (poll . "Posted a poll")
    (update . "Edited"))
  "Action strings keyed by notification type.
Types are those of the Mastodon API.")

(defun mastodon-notifications--alist-by-value (str field json)
  "From JSON, return the alist whose FIELD value matches STR.
JSON is a list of alists."
  (cl-some (lambda (y)
             (when (string= str (alist-get field y))
               y))
           json))

(defun mastodon-notifications--group-accounts (ids json)
  "For IDS, return account data in JSON."
  (cl-loop
   for x in ids
   collect (mastodon-notifications--alist-by-value x 'id json)))

(defun mastodon-notifications--format-note (group status accounts)
  "Format for a GROUP notification.
STATUS is the status's JSON.
ACCOUNTS is data of the accounts that have reacted to the notification."
  (let ((folded nil))
    ;; FIXME: apply/refactor filtering as per/with `mastodon-tl--toot'
    (let-alist group
      ;; .sample_account_ids .status_id .notifications_count
      ;; .most_recent_notifiation_id
      (let* (;(type .type)
             (type-sym (intern .type))
             (profile-note
              (when (eq type-sym 'follow_request)
                (let ((str (mastodon-tl--field 'note (car accounts))))
                  (if mastodon-notifications--profile-note-in-foll-reqs-max-length
                      (string-limit str mastodon-notifications--profile-note-in-foll-reqs-max-length)
                    str))))
             ;; (follower (car .sample_account_ids))
             (follower-name (mastodon-tl--field 'username (car accounts)))
             (filtered (mastodon-tl--field 'filtered status)) ;;toot))
             (filters (when filtered
                        (mastodon-tl--current-filters filtered))))
        (unless (and filtered (assoc "hide" filters))
          (if (member type-sym '(follow follow_request))
              ;; FIXME: handle follow requests, polls
              (insert "TODO: follow-req\n")
            (mastodon-notifications--insert-note
             ;; toot
             (if (member type-sym '(follow follow_request))
                 ;; Using reblog with an empty id will mark this as something
                 ;; non-boostable/non-favable.
                 ;; status
                 status
               ;; (cons '(reblog (id . nil)) status) ;;note))
               ;; reblogs/faves use 'note' to process their own json not the
               ;; toot's. this ensures following etc. work on such notifs
               status) ;; FIXME: fix following on these notifs
             ;; body
             (let ((body (if-let ((match (assoc "warn" filters)))
                             (mastodon-tl--spoiler status (cadr match))
                           (mastodon-tl--clean-tabs-and-nl
                            (if (mastodon-tl--has-spoiler status)
                                (mastodon-tl--spoiler status)
                              (if (eq type-sym 'follow_request)
                                  (mastodon-tl--render-text profile-note)
                                (mastodon-tl--content status)))))))
               (cond ((eq type-sym 'follow)
                      (propertize "Congratulations, you have a new follower!"
                                  'face 'default))
                     ((eq type-sym 'follow_request)
                      (concat
                       (propertize
                        (format "You have a follow request from... %s"
                                follower-name)
                        'face 'default)
                       (when mastodon-notifications--profile-note-in-foll-reqs
                         (concat
                          ":\n"
                          (mastodon-notifications--comment-note-text body)))))
                     ((member type-sym '(favourite reblog))
                      (mastodon-notifications--comment-note-text body))
                     (t body)))
             ;; author-byline
             #'mastodon-tl--byline-author
             ;; action-byline
             (unless (member type-sym '(mention))
               (mastodon-notifications--byline-concat
                (alist-get type-sym mastodon-notifications--action-alist)))
             ;; action authors
             (cond ((member type-sym '(mention))
                    "") ;; mentions are normal statuses
                   ((member type-sym '(favourite reblog update))
                    (mastodon-notifications--byline-accounts accounts status group))
                   ((eq type-sym 'follow_request)
                    (mastodon-tl--byline-uname-+-handle status nil (car accounts))))
             .status_id
             ;; base toot
             (when (member type-sym '(favourite reblog))
               status)
             folded group accounts))))))) ;; insert status still needs our group data

;; FIXME: this is copied from `mastodon-tl--insert-status'
;; we could probably cull a lot of the code so its just for notifs
(defun mastodon-notifications--insert-note
    (toot body author-byline action-byline action-authors
          &optional id base-toot unfolded group accounts)
  "Display the content and byline of timeline element TOOT.
BODY will form the section of the toot above the byline.
AUTHOR-BYLINE is an optional function for adding the author
portion of the byline that takes one variable. By default it is
`mastodon-tl--byline-author'.
ACTION-BYLINE is also an optional function for adding an action,
such as boosting favouriting and following to the byline. It also
takes a single function. By default it is
`mastodon-tl--byline-boosted'.
ID is that of the status if it is a notification, which is
attached as a `item-id' property if provided. If the
status is a favourite or boost notification, BASE-TOOT is the
JSON of the toot responded to.
UNFOLDED is a boolean meaning whether to unfold or fold item if foldable.
NO-BYLINE means just insert toot body, used for folding."
  (let* ((type (alist-get 'type (or group toot)))
         (toot-foldable
          (and mastodon-tl--fold-toots-at-length
               (length> body mastodon-tl--fold-toots-at-length))))
    (insert
     (propertize ;; body + byline:
      (concat
       (concat action-authors
               action-byline)
       (propertize ;; body only:
        body
        'toot-body t) ;; includes newlines etc. for folding
       ;; byline:
       "\n"
       (mastodon-tl--byline toot author-byline nil nil
                            base-toot group))
      'item-type    'toot
      'item-id      (or id ; notification's own id
                        (alist-get 'id toot)) ; toot id
      'base-item-id (mastodon-tl--item-id
                     ;; if status is a notif, get id from base-toot
                     ;; (-tl--item-id toot) will not work here:
                     (or base-toot
                         toot)) ; else normal toot with reblog check
      'item-json    toot
      'base-toot    base-toot
      'cursor-face 'mastodon-cursor-highlight-face
      'toot-foldable toot-foldable
      'toot-folded (and toot-foldable (not unfolded))
      'notification-type type
      'notification-group group
      'notification-accounts accounts)
     "\n")))

;; FIXME: REFACTOR with -tl--byline?:
;; we provide account directly, rather than let-alisting toot
;; almost everything is .account.field anyway
;; but toot still needed also, for attachments, etc.
(defun mastodon-notifications--byline-accounts
    (accounts toot group &optional avatar compact)
  "Propertize author byline ACCOUNTS for TOOT, the item responded to.
With arg AVATAR, include the account's avatar image.
When DOMAIN, force inclusion of user's domain in their handle."
  (let ((total (alist-get 'notifications_count group))
        (accts 2))
    (concat
     (cl-loop
      for account in accounts
      repeat accts
      concat
      (let-alist account
        (concat
         ;; avatar insertion moved up to `mastodon-tl--byline' by
         ;; default to be outside 'byline propt.
         (when (and avatar ; used by `mastodon-profile--format-user'
                    mastodon-tl--show-avatars
                    mastodon-tl--display-media-p
                    (mastodon-tl--image-trans-check))
           (mastodon-media--get-avatar-rendering .avatar))
         (let ((uname (mastodon-tl--byline-username toot account))
               (handle (concat
                        "("
                        (mastodon-tl--byline-handle toot nil account)
                        ")")))
           (if compact
               ;; FIXME: this doesn't work to make a link from a username:
               (propertize handle 'display uname)
             (concat uname handle)))
         "\n"))) ;; FIXME: only if not last handle
     (if (< accts total)
         (let ((diff (- total accts)))
           ;; FIXME: help echo all remaining accounts?
           (format "\nand %s other%s" diff (if (= 1 diff) "" "s")))))))

(defun mastodon-notifications--render (json)
  "Display grouped notifications in JSON."
  ;; (setq masto-grouped-notifs json)
  (let ((groups (alist-get 'notification_groups json)))
    (cl-loop
     for g in groups
     for start-pos = (point)
     for accounts = (mastodon-notifications--group-accounts
                     (alist-get 'sample_account_ids g)
                     (alist-get 'accounts json))
     for status = (mastodon-notifications--alist-by-value
                   (alist-get 'status_id g) 'id
                   (alist-get 'statuses json))
     do (mastodon-notifications--format-note g status accounts)
     (when mastodon-tl--display-media-p
       ;; images-in-notifs custom is handeld in
       ;; `mastodon-tl--media-attachment', not here
       (mastodon-media--inline-images start-pos (point))))))

(defun mastodon-notifications--timeline (json)
  "Format JSON in Emacs buffer."
  (if (seq-empty-p json)
      (user-error "Looks like you have no (more) notifications for now")
    (mastodon-notifications--render json)
    (goto-char (point-min))))

(defun mastodon-notifications--get-mentions ()
  "Display mention notifications in buffer."
  (interactive)
  (mastodon-notifications-get "mention" "mentions"))

(defun mastodon-notifications--get-favourites ()
  "Display favourite notifications in buffer."
  (interactive)
  (mastodon-notifications-get "favourite" "favourites"))

(defun mastodon-notifications--get-boosts ()
  "Display boost notifications in buffer."
  (interactive)
  (mastodon-notifications-get "reblog" "boosts"))

(defun mastodon-notifications--get-polls ()
  "Display poll notifications in buffer."
  (interactive)
  (mastodon-notifications-get "poll" "polls"))

(defun mastodon-notifications--get-statuses ()
  "Display status notifications in buffer.
Status notifications are created when you call
`mastodon-tl--enable-notify-user-posts'."
  (interactive)
  (mastodon-notifications-get "status" "statuses"))

(defun mastodon-notifications--filter-types-list (type)
  "Return a list of notification types with TYPE removed."
  (let ((types (mapcar #'car mastodon-notifications--types-alist)))
    (remove type types)))

(defun mastodon-notifications--clear-all ()
  "Clear all notifications."
  (interactive)
  (when (y-or-n-p "Clear all notifications?")
    (let ((response
           (mastodon-http--post (mastodon-http--api "notifications/clear"))))
      (mastodon-http--triage
       response (lambda (_)
                  (when mastodon-tl--buffer-spec
                    (mastodon-tl--reload-timeline-or-profile))
                  (message "All notifications cleared!"))))))

(defun mastodon-notifications--clear-current ()
  "Dismiss the notification at point."
  (interactive)
  (let* ((id (or (mastodon-tl--property 'item-id)
                 (mastodon-tl--field 'id
                                     (mastodon-tl--property 'item-json))))
         (response
          (mastodon-http--post (mastodon-http--api
                                (format "notifications/%s/dismiss" id)))))
    (mastodon-http--triage
     response (lambda (_)
                (when mastodon-tl--buffer-spec
                  (mastodon-tl--reload-timeline-or-profile))
                (message "Notification dismissed!")))))

(defun mastodon-notifications--get-unread-count ()
  "Return the number of unread notifications for the current account."
  ;; params: limit - max 1000, default 100, types[], exclude_types[], account_id
  (let* ((endpoint "notifications/unread_count")
         (url (mastodon-http--api endpoint))
         (resp (mastodon-http--get-json url)))
    (alist-get 'count resp)))

(provide 'mastodon-notifications)
;;; mastodon-notifications.el ends here
