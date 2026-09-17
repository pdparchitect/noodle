# Conversation and attachment annotations

Add a comment to selected text or a captured region, then send it with your
conversation. Saving an annotation adds it to the draft; it does not send it.

## Annotate a conversation

1. Select text and press **⌘⇧A**, or choose **Conversation → Add Annotation…**.
   To mark a region instead, press **⌘⇧R** or choose
   **Conversation → Annotate Region…**, then drag a rectangle or click a point.
2. Enter your comment. Check that the quote or captured region is correct.
3. Click **Save** or press **⌘Return**. Press **Escape** to cancel.

Text annotations retain the selected quote and its source message. Region
annotations capture the content inside the current Noodle window. Switching
conversations cancels an unfinished annotation.

## Annotate an attachment

Open an attachment in Noodle's Quick Look preview, then:

1. Select text and press **⌘⇧A**, or choose **Preview → Add Annotation**.
   For images, this starts region selection. If text selection is unavailable,
   the editor labels the comment as applying to the whole attachment.
2. To capture a region of any preview, press **⌘⇧R**. Drag a rectangle or click
   to place a marker, then check the captured image before saving.
3. Enter your comment and click **Save** or press **⌘Return**. **Escape** or the
   close button cancels and returns focus to the preview.

Hold Escape to dismiss the annotation, then release and press it again to close
Quick Look. These actions apply to Noodle's preview, not external Preview.app
windows. The original attachment is unchanged.

Shortcuts follow the active conversation or preview. Change them in
**Settings → Keybindings**; menus show your current bindings. See
[keyboard shortcuts](keyboard-shortcuts.md).

## Review, edit, and send

Click a saved annotation in the draft to review its comment and quote or marked
image. Choose **Edit Comment** to change an unsent comment; **Save** updates it
and **Cancel** discards the edit. Remove unwanted feedback with the draft
attachment's remove button. Saved drafts survive relaunch.

Use the conversation's **Send** button when the feedback is ready. Every
participant receives the annotation through normal message delivery. Submitted
annotations are read-only, including messages waiting for delivery.

## Saved content and privacy

Text annotations store the comment and quote in a text attachment. Region
annotations store a PNG snapshot with an orange marker. Older PDF annotations
remain readable, and editing an older unsent annotation preserves its format.

Capture is limited to the selected Noodle conversation or attachment-preview
window. It does not require additional Accessibility or Screen Recording
permission. A region is a saved snapshot; it does not track content after
scrolling or zooming.

Bots receive the comment, source reference, and saved content. For metadata and
CLI access, see the generated [message reference](message-reference.md).

[Documentation](README.md)
