import Foundation
import HubLink
import NoodleCore
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// A conversation: its name, its newest page of messages in a ListView with the pages before a click away, and a
/// composer that keeps each conversation's unsent words and saves what is sent to the store.
final class ConversationPane {
    let root: Grid
    /// After a message is saved, with its conversation, so the list can move it up.
    var onSent: ((UUID) -> Void)?
    private let title: TextBlock
    private let detail: TextBlock
    private let messages: ListView
    private let composer: TextBox
    private let send: Button
    private var store: Store?
    private var conversation: BotConversation?
    private var drafts = ConversationDrafts()
    /// The oldest message shown, once Show Earlier Messages was clicked.
    private var firstShownID: UUID?

    init() {
        root = Xaml.load(Self.layout) as! Grid
        title = Xaml.find(root, "Title")
        detail = Xaml.find(root, "Detail")
        messages = Xaml.find(root, "Messages")
        composer = Xaml.find(root, "Composer")
        send = Xaml.find(root, "Send")
        composer.textChanged.addHandler { [weak self] _, _ in self?.draftChanged() }
        send.click.addHandler { [weak self] _, _ in MainActor.assumeIsolated { self?.sendDraft() } }
    }

    func show(_ conversation: BotConversation, in store: Store) {
        if let shown = self.conversation { drafts[shown.id].text = composer.text }
        if conversation.id != self.conversation?.id { firstShownID = nil }
        self.store = store
        self.conversation = conversation
        let name = conversation.title(among: store.agents)
        title.text = name
        detail.text = store.detail(of: conversation) ?? ""
        let unavailable = store.composerUnavailableReason(for: conversation)
        composer.isEnabled = unavailable == nil
        composer.placeholderText = unavailable ?? "Message \(name)"
        if composer.text != drafts[conversation.id].text { composer.text = drafts[conversation.id].text }
        draftChanged()
        showMessages(scrollingToEnd: true)
    }

    func setScenarioDraft(_ text: String, for id: UUID) {
        drafts[id].text = text
        if conversation?.id == id { composer.text = text }
    }

    func showProblem(_ problem: String, detail: String) {
        conversation = nil
        title.text = problem
        self.detail.text = detail
        messages.items.clear()
        composer.isEnabled = false
        send.isEnabled = false
    }

    private func showMessages(scrollingToEnd: Bool) {
        guard let store, let conversation else { return }
        let all = store.messages(in: conversation)
        let first = TranscriptPaging.firstShown(in: all, firstShownID: firstShownID, reading: nil)
        let items = messages.items!
        items.clear()
        if first > 0 { items.append(earlierMessages(before: first, in: all)) }
        for index in all.indices.dropFirst(first) {
            let message = all[index]
            // The message before the first shown one counts, loaded or not.
            if let caption = TranscriptTimestamp.caption(for: message.createdAt, after: index > 0 ? all[index - 1].createdAt : nil) {
                items.append(notice(caption))
            }
            items.append(message.author == .system ? notice(message.body) : row(for: message, in: store))
        }
        if scrollingToEnd, items.size > 0 { try? messages.scrollIntoView(items.getAt(items.size - 1)) }
    }

    private func earlierMessages(before first: Int, in all: [ChatMessage]) -> UIElement {
        let button = Xaml.load(Self.earlierRow) as! Button
        button.click.addHandler { [weak self] _, _ in
            self?.firstShownID = TranscriptPaging.pageBefore(first, in: all)
            self?.showMessages(scrollingToEnd: false)
        }
        return button
    }

    private func draftChanged() {
        guard let conversation else { return }
        drafts[conversation.id].text = composer.text
        send.isEnabled = composer.isEnabled && drafts[conversation.id].canSend
    }

    @MainActor private func sendDraft() {
        guard let store, let conversation, drafts[conversation.id].canSend else { return }
        do {
            _ = try store.send(drafts[conversation.id].text, to: conversation)
            drafts.clear(conversation.id)
            composer.text = ""
            onSent?(conversation.id)
        } catch {
            detail.text = "Noodle could not send this message. \(error.localizedDescription)"
        }
    }

    private func row(for message: ChatMessage, in store: Store) -> UIElement {
        let row = Xaml.load(Self.messageRow) as! Grid
        let author = store.authorName(message.author)
        let picture: PersonPicture = Xaml.find(row, "Picture")
        picture.displayName = author
        let name: TextBlock = Xaml.find(row, "Author")
        name.text = author
        let time: TextBlock = Xaml.find(row, "Time")
        time.text = message.createdAt.formatted(date: .omitted, time: .shortened)
        let body: TextBlock = Xaml.find(row, "Body")
        body.text = message.body
        // Under the person's own message: whether it reached the conversation, and whether a bot got it.
        if message.author == .user {
            let delivery: TextBlock = Xaml.find(row, "Delivery")
            delivery.text = message.delivery.title
            delivery.visibility = .visible
        }
        return row
    }

    private func notice(_ text: String) -> UIElement {
        let notice = Xaml.load(Self.noticeRow) as! TextBlock
        notice.text = text
        return notice
    }

    private static let layout = """
    <Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <StackPanel Padding="24,16,24,8" Spacing="2">
        <TextBlock x:Name="Title" Style="{StaticResource SubtitleTextBlockStyle}" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Detail" Style="{StaticResource CaptionTextBlockStyle}"
                   Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <ListView x:Name="Messages" Grid.Row="1" SelectionMode="None" Padding="8,0,8,8"/>
      <Grid Grid.Row="2" Padding="24,8,24,20" ColumnSpacing="8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox x:Name="Composer" AcceptsReturn="True" TextWrapping="Wrap" MaxHeight="160"/>
        <Button x:Name="Send" Grid.Column="1" Style="{StaticResource AccentButtonStyle}" VerticalAlignment="Bottom" IsEnabled="False"
                ToolTipService.ToolTip="Send" AutomationProperties.Name="Send">
          <FontIcon Glyph="&#xE724;" FontSize="16"/>
        </Button>
      </Grid>
    </Grid>
    """

    private static let messageRow = """
    <Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" ColumnSpacing="12" Padding="0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <PersonPicture x:Name="Picture" Width="32" Height="32" VerticalAlignment="Top"/>
      <StackPanel Grid.Column="1" Spacing="2">
        <StackPanel Orientation="Horizontal" Spacing="8">
          <TextBlock x:Name="Author" Style="{StaticResource BodyStrongTextBlockStyle}"/>
          <TextBlock x:Name="Time" Style="{StaticResource CaptionTextBlockStyle}" VerticalAlignment="Center"
                     Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
        </StackPanel>
        <TextBlock x:Name="Body" TextWrapping="Wrap" IsTextSelectionEnabled="True"/>
        <TextBlock x:Name="Delivery" Style="{StaticResource CaptionTextBlockStyle}" Visibility="Collapsed"
                   Foreground="{ThemeResource TextFillColorTertiaryBrush}"/>
      </StackPanel>
    </Grid>
    """

    private static let earlierRow = """
    <Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Content="Show Earlier Messages" HorizontalAlignment="Center" Margin="0,8"/>
    """

    private static let noticeRow = """
    <TextBlock xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
               Style="{StaticResource CaptionTextBlockStyle}" Foreground="{ThemeResource TextFillColorSecondaryBrush}"
               HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,8"/>
    """
}
