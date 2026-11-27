import Foundation
import HubLink
import NoodleCore
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// The one window: WinUI's title bar drawn into the window over Mica, the bots and groups in a NavigationView's
/// pane, and the selected conversation beside it. The theme follows Windows' light or dark mode.
final class MainWindow {
    private let window = Window()
    private let navigation: NavigationView
    private let conversation: ConversationPane
    private var store: Store?

    init() {
        let root = Xaml.load(Self.shell) as! Grid
        navigation = Xaml.find(root, "Navigation")
        let titleBar: TitleBar = Xaml.find(root, "TitleBar")
        conversation = ConversationPane()
        navigation.content = conversation.root
        conversation.onSent = { [weak self] id in self?.load(selecting: id) }

        window.title = "Noodle"
        window.systemBackdrop = MicaBackdrop()
        window.extendsContentIntoTitleBar = true
        window.content = root
        try? window.setTitleBar(titleBar)
        titleBar.paneToggleRequested.addHandler { [navigation] _, _ in navigation.isPaneOpen.toggle() }
        navigation.selectionChanged.addHandler { [weak self] _, args in
            guard let item = args?.selectedItem as? ConversationItem else { return }
            self?.show(item.conversationID)
        }
        load()
    }

    func activate() { try? window.activate() }

    /// Reads the store again, as after a message is sent, which can move its conversation up the list.
    private func load(selecting selection: UUID? = nil) {
        do {
            let store = try Store()
            self.store = store
            fillPane(with: store, selecting: selection)
        } catch {
            conversation.showProblem("Noodle could not read its store at \(Store.defaultFolder.path).", detail: "\(error)")
        }
    }

    private func fillPane(with store: Store, selecting selection: UUID?) {
        let items = navigation.menuItems!
        items.clear()
        var first: NavigationViewItem?, selected: NavigationViewItem?
        for (header, conversations) in [("Pinned", store.pinned), ("Bots", store.bots), ("Groups", store.groups)]
        where !conversations.isEmpty {
            let heading = NavigationViewItemHeader()
            heading.content = header
            items.append(heading)
            for conversation in conversations {
                let item = item(for: conversation, in: store)
                first = first ?? item
                if conversation.id == selection { selected = item }
                items.append(item)
            }
        }
        if let item = selected ?? first {
            navigation.selectedItem = item
        } else {
            conversation.showProblem("No bots yet.", detail: "Noodle reads bots from \(store.folder.path). Set NOODLE_DATA to read another folder.")
        }
    }

    private func item(for conversation: BotConversation, in store: Store) -> NavigationViewItem {
        let item = ConversationItem(conversationID: conversation.id)
        let title = conversation.title(among: store.agents)
        // The name, and on its right when anything was last said there.
        let row = Xaml.load(Self.row) as! Grid
        (Xaml.find(row, "Title") as TextBlock).text = title
        (Xaml.find(row, "Time") as TextBlock).text = SidebarTimestamp.text(for: store.lastMessageDate(of: conversation))
        item.content = row
        // Screen readers say the name alone, as they did when it was the row's only content.
        try? AutomationProperties.setName(item, title)
        let icon = FontIcon()
        // Contact for a bot, People for a group, from Segoe Fluent Icons.
        icon.glyph = conversation.kind == .direct ? "\u{E77B}" : "\u{E716}"
        item.icon = icon
        if store.unread.contains(conversation.id) { item.infoBadge = InfoBadge() }
        if let about = store.about(conversation) { try? ToolTipService.setToolTip(item, about) }
        return item
    }

    private func show(_ id: UUID) {
        guard let store, let conversation = store.conversation(withID: id) else { return }
        self.conversation.show(conversation, in: store)
    }

    private static let row = """
    <Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" ColumnSpacing="8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="Title" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
      <TextBlock x:Name="Time" Grid.Column="1" Style="{StaticResource CaptionTextBlockStyle}" VerticalAlignment="Center"
                 Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
    </Grid>
    """

    private static let shell = """
    <Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TitleBar x:Name="TitleBar" Title="Noodle" IsBackButtonVisible="False" IsPaneToggleButtonVisible="True"/>
      <NavigationView x:Name="Navigation" Grid.Row="1" PaneDisplayMode="Left" OpenPaneLength="280"
                      IsSettingsVisible="False" IsBackButtonVisible="Collapsed" IsPaneToggleButtonVisible="False"/>
    </Grid>
    """
}

/// A sidebar row that knows its conversation, so a selection finds it without boxing an ID into Tag.
private final class ConversationItem: NavigationViewItem {
    let conversationID: UUID

    init(conversationID: UUID) {
        self.conversationID = conversationID
        super.init()
    }
}

/// Loads markup with XAML's own parser, so styles and theme resources resolve as in a XAML file.
enum Xaml {
    static func load(_ markup: String) -> Any { try! XamlReader.load(markup)! }

    static func find<Element>(_ root: FrameworkElement, _ name: String) -> Element {
        try! root.findName(name) as! Element
    }
}
