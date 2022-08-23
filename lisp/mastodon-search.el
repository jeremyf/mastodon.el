;;; mastodon-search.el --- Search functions for mastodon.el  -*- lexical-binding: t -*-

;; Copyright (C) 2017-2019 Marty Hiatt
;; Author: Marty Hiatt <martianhiatus@riseup.net>
;; Maintainer: Marty Hiatt <martianhiatus@riseup.net>
;; Version: 0.10.0
;; Package-Requires: ((emacs "27.1"))
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

;; A basic search function for mastodon.el

;;; Code:
(require 'json)

(autoload 'mastodon-http--get-json "mastodon-http")
(autoload 'mastodon-tl--as-string "mastodon-tl")
(autoload 'mastodon-mode "mastodon")
(autoload 'mastodon-tl--set-face "mastodon-tl")
(autoload 'mastodon-tl--render-text "mastodon-tl")
(autoload 'mastodon-tl--as-string "mastodon-tl")
(autoload 'mastodon-auth--access-token "mastodon-auth")
(autoload 'mastodon-http--get-search-json "mastodon-http")
(autoload 'mastodon-http--api "mastodon-http")

(defvar mastodon-instance-url)
(defvar mastodon-tl--link-keymap)
(defvar mastodon-http--timeout)
(defvar mastodon-toot--enable-completion-for-mentions)

;; functions for company completion of mentions in mastodon-toot

(defun mastodon-search--get-user-info-@ (account)
  "Get user handle, display name and account URL from ACCOUNT."
  (list (cdr (assoc 'display_name account))
        (concat "@" (cdr (assoc 'acct account)))
        (cdr (assoc 'url account))))

(defun mastodon-search--search-accounts-query (query)
  "Prompt for a search QUERY and return accounts synchronously.
Returns a nested list containing user handle, display name, and URL."
  (interactive "sSearch mastodon for: ")
  (let* ((url (mastodon-http--api "accounts/search"))
         (response (if (equal mastodon-toot--enable-completion-for-mentions "following")
                       (mastodon-http--get-search-json url query "following=true")
                     (mastodon-http--get-search-json url query))))
    (mapcar #'mastodon-search--get-user-info-@ response)))

;; functions for tags completion:

(defun mastodon-search--search-tags-query (query)
  "Return an alist containing tag strings plus their URLs.
QUERY is the string to search."
  (interactive "sSearch for hashtag: ")
  (let* ((url (format "%s/api/v2/search" mastodon-instance-url))
         (type-param (concat "type=hashtags"))
         (response (mastodon-http--get-search-json url query type-param))
         (tags (alist-get 'hashtags response)))
    (mapcar #'mastodon-search--get-hashtag-info tags)))

;; functions for mastodon search

(defun mastodon-search--search-query (query)
  "Prompt for a search QUERY and return accounts, statuses, and hashtags."
  (interactive "sSearch mastodon for: ")
  (let* ((url (format "%s/api/v2/search" mastodon-instance-url))
         (buffer (format "*mastodon-search-%s*" query))
         (response (mastodon-http--get-search-json url query))
         (accts (alist-get 'accounts response))
         (tags (alist-get 'hashtags response))
         (statuses (alist-get 'statuses response))
         ;; this is now done in search--insert-users-propertized
         ;; (user-ids (mapcar #'mastodon-search--get-user-info
         ;; accts)) ; returns a list of three-item lists
         (tags-list (mapcar #'mastodon-search--get-hashtag-info
                            tags))
         ;; (status-list (mapcar #'mastodon-search--get-status-info
         ;; statuses))
         (status-ids-list (mapcar 'mastodon-search--get-id-from-status
                                  statuses))
         (toots-list-json (mapcar #'mastodon-search--fetch-full-status-from-id
                                  status-ids-list)))
    (with-current-buffer (get-buffer-create buffer)
      (switch-to-buffer buffer)
      (mastodon-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; user results:
        (insert (mastodon-tl--set-face
                 (concat "\n ------------\n"
                         " USERS\n"
                         " ------------\n\n")
                 'success))
        (mastodon-search--insert-users-propertized accts :note)
        ;; hashtag results:
        (insert (mastodon-tl--set-face
                 (concat "\n ------------\n"
                         " HASHTAGS\n"
                         " ------------\n\n")
                 'success))
        (mapc (lambda (el)
                (insert " : #"
                        (propertize (car el)
                                    'mouse-face 'highlight
                                    'mastodon-tag (car el)
                                    'mastodon-tab-stop 'hashtag
                                    'help-echo (concat "Browse tag #" (car el))
                                    'keymap mastodon-tl--link-keymap)
                        " : \n\n"))
              tags-list)
        ;; status results:
        (insert (mastodon-tl--set-face
                 (concat "\n ------------\n"
                         " STATUSES\n"
                         " ------------\n")
                 'success))
        (mapc 'mastodon-tl--toot toots-list-json)
        (goto-char (point-min))))))

(defun mastodon-search--insert-users-propertized (json &optional note)
  "Insert users list into the buffer.
JSON is the data from the server.. If NOTE is non-nil, include
user's profile note. This is also called by
`mastodon-tl--get-follow-suggestions' and
`mastodon-profile--insert-follow-requests'."
  (mapc (lambda (acct)
          (let ((user (mastodon-search--get-user-info acct)))
            (insert
             (propertize
              (concat (propertize (car user)
                                  'face 'mastodon-display-name-face
                                  'byline t
                                  'toot-id "0")
                      " : \n : "
                      (propertize (concat "@" (cadr user))
                                  'face 'mastodon-handle-face
                                  'mouse-face 'highlight
		                          'mastodon-tab-stop 'user-handle
		                          'keymap mastodon-tl--link-keymap
                                  'mastodon-handle (concat "@" (cadr user))
		                          'help-echo (concat "Browse user profile of @" (cadr user)))
                      " : \n"
                      (if note
                          (mastodon-tl--render-text (cadddr user) nil)
                        "")
                      "\n")
              'toot-json acct)))) ; so named for compat w other processing functions
        json))

(defun mastodon-search--get-user-info (account)
  "Get user handle, display name, account URL and profile note from ACCOUNT."
  (list (if (not (equal "" (alist-get 'display_name account)))
            (alist-get 'display_name account)
          (alist-get 'username account))
        (alist-get 'acct account)
        (alist-get 'url account)
        (alist-get 'note account)))

(defun mastodon-search--get-hashtag-info (tag)
  "Get hashtag name and URL from TAG."
  (list (alist-get 'name tag)
        (alist-get 'url tag)))

(defun mastodon-search--get-status-info (status)
  "Get ID, timestamp, content, and spoiler from STATUS."
  (list (alist-get 'id status)
        (alist-get 'created_at status)
        (alist-get 'spoiler_text status)
        (alist-get 'content status)))

(defun mastodon-search--get-id-from-status (status)
  "Fetch the id from a STATUS returned by a search call to the server.

We use this to fetch the complete status from the server."
  (alist-get 'id status))

(defun mastodon-search--fetch-full-status-from-id (id)
  "Fetch the full status with id ID from the server.

This allows us to access the full account etc. details and to
render them properly."
  (let* ((url (concat mastodon-instance-url "/api/v1/statuses/" (mastodon-tl--as-string id)))
         (json (mastodon-http--get-json url)))
    json))

(provide 'mastodon-search)
;;; mastodon-search.el ends here
