use muda::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    Settings,
    SettingsLegacy,
    OpenBrowserDataPanel,
    ShowMessages,
    ResetConversation,
    HideFae,
    Stop,
    PermissionsMicrophone,
    PermissionsContacts,
    PermissionsCalendars,
    PermissionsReminders,
    PermissionsMailNotes,
    OpenPrivacySecurity,
    Scheduler,
    Skills,
    EditSoul,
    EditCustomInstructions,
    AskFae,
    AskAboutShortcuts,
    AskAboutModels,
    AskAboutPrivacy,
    AskAboutTools,
    MemoryInbox,
    RescueMode,
    Quit,
    /// Push-to-talk toggle: the "Talk to Fae" menu item and the Messages
    /// panel's mic button (capture ends on pause, second toggle, or Stop).
    TalkToggle,
    /// Stdout-only events from the orb long-press gesture: press-and-hold
    /// starts capture, release sends. Never in the context menu —
    /// `action_from_id` has no mapping for them.
    TalkStart,
    TalkStop,
}

impl MenuAction {
    pub fn as_str(self) -> &'static str {
        match self {
            MenuAction::Settings => "settings",
            MenuAction::SettingsLegacy => "settings_legacy",
            MenuAction::OpenBrowserDataPanel => "open_browser_data_panel",
            MenuAction::ShowMessages => "show_messages",
            MenuAction::ResetConversation => "reset_conversation",
            MenuAction::HideFae => "hide_fae",
            MenuAction::Stop => "stop",
            MenuAction::PermissionsMicrophone => "permissions_microphone",
            MenuAction::PermissionsContacts => "permissions_contacts",
            MenuAction::PermissionsCalendars => "permissions_calendars",
            MenuAction::PermissionsReminders => "permissions_reminders",
            MenuAction::PermissionsMailNotes => "permissions_mail_notes",
            MenuAction::OpenPrivacySecurity => "open_privacy_security",
            MenuAction::Scheduler => "scheduler",
            MenuAction::Skills => "skills",
            MenuAction::EditSoul => "edit_soul",
            MenuAction::EditCustomInstructions => "edit_custom_instructions",
            MenuAction::AskFae => "ask_fae",
            MenuAction::AskAboutShortcuts => "ask_about_shortcuts",
            MenuAction::AskAboutModels => "ask_about_models",
            MenuAction::AskAboutPrivacy => "ask_about_privacy",
            MenuAction::AskAboutTools => "ask_about_tools",
            MenuAction::MemoryInbox => "memory_inbox",
            MenuAction::RescueMode => "rescue_mode",
            MenuAction::Quit => "quit",
            MenuAction::TalkToggle => "talk_toggle",
            MenuAction::TalkStart => "talk_start",
            MenuAction::TalkStop => "talk_stop",
        }
    }
}

pub struct OrbMenu {
    pub menu: Menu,
}

impl OrbMenu {
    pub fn new() -> Result<Self, muda::Error> {
        let menu = Menu::new();
        // Right ⌥ hold-to-talk is the primary gesture; this item is the
        // discoverable mouse fallback (capture ends on pause or via Stop).
        append_item(&menu, MenuAction::TalkToggle, "Talk to Fae")?;
        append_item(&menu, MenuAction::Settings, "Settings…")?;
        append_item(&menu, MenuAction::SettingsLegacy, "Settings (legacy)…")?;
        append_item(&menu, MenuAction::ShowMessages, "Messages…")?;
        append_item(
            &menu,
            MenuAction::OpenBrowserDataPanel,
            "Open Browser/Data Panel",
        )?;
        append_separator(&menu)?;
        append_item(&menu, MenuAction::ResetConversation, "Reset Conversation")?;
        append_item(&menu, MenuAction::HideFae, "Hide Fae")?;
        append_item(&menu, MenuAction::Stop, "Stop")?;
        append_separator(&menu)?;
        append_item(
            &menu,
            MenuAction::PermissionsMicrophone,
            "Microphone — Check Permission",
        )?;
        append_item(
            &menu,
            MenuAction::PermissionsContacts,
            "Contacts — Check Permission",
        )?;
        append_item(
            &menu,
            MenuAction::PermissionsCalendars,
            "Calendars — Check Permission",
        )?;
        append_item(
            &menu,
            MenuAction::PermissionsReminders,
            "Reminders — Check Permission",
        )?;
        append_item(
            &menu,
            MenuAction::PermissionsMailNotes,
            "Mail & Notes (Automation)…",
        )?;
        append_item(
            &menu,
            MenuAction::OpenPrivacySecurity,
            "Open Privacy & Security…",
        )?;
        append_separator(&menu)?;
        append_item(&menu, MenuAction::Scheduler, "Scheduler")?;
        append_item(&menu, MenuAction::Skills, "Skills")?;
        append_item(&menu, MenuAction::EditSoul, "Edit Soul…")?;
        append_item(
            &menu,
            MenuAction::EditCustomInstructions,
            "Edit Custom Instructions…",
        )?;
        append_separator(&menu)?;
        append_item(&menu, MenuAction::AskFae, "Ask Fae…")?;
        append_item(&menu, MenuAction::AskAboutShortcuts, "Ask About Shortcuts")?;
        append_item(&menu, MenuAction::AskAboutModels, "Ask About Models")?;
        append_item(&menu, MenuAction::AskAboutPrivacy, "Ask About Privacy")?;
        append_item(&menu, MenuAction::AskAboutTools, "Ask About Tools")?;
        append_item(&menu, MenuAction::MemoryInbox, "Memory Inbox…")?;
        append_item(&menu, MenuAction::RescueMode, "Rescue Mode…")?;
        append_separator(&menu)?;
        append_item(&menu, MenuAction::Quit, "Quit Fae")?;
        Ok(Self { menu })
    }

    pub fn action_for_event(event: &MenuEvent) -> Option<MenuAction> {
        action_from_id(event.id())
    }
}

fn append_item(menu: &Menu, action: MenuAction, label: &str) -> Result<(), muda::Error> {
    menu.append(&MenuItem::with_id(id(action), label, true, None))
}

fn append_separator(menu: &Menu) -> Result<(), muda::Error> {
    menu.append(&PredefinedMenuItem::separator())
}

fn id(action: MenuAction) -> MenuId {
    MenuId::new(match action {
        MenuAction::Settings => "settings",
        MenuAction::SettingsLegacy => "settings_legacy",
        MenuAction::OpenBrowserDataPanel => "open_browser_data_panel",
        MenuAction::ShowMessages => "show_messages",
        MenuAction::ResetConversation => "reset_conversation",
        MenuAction::HideFae => "hide_fae",
        MenuAction::Stop => "stop",
        MenuAction::PermissionsMicrophone => "permissions_microphone",
        MenuAction::PermissionsContacts => "permissions_contacts",
        MenuAction::PermissionsCalendars => "permissions_calendars",
        MenuAction::PermissionsReminders => "permissions_reminders",
        MenuAction::PermissionsMailNotes => "permissions_mail_notes",
        MenuAction::OpenPrivacySecurity => "open_privacy_security",
        MenuAction::Scheduler => "scheduler",
        MenuAction::Skills => "skills",
        MenuAction::EditSoul => "edit_soul",
        MenuAction::EditCustomInstructions => "edit_custom_instructions",
        MenuAction::AskFae => "ask_fae",
        MenuAction::AskAboutShortcuts => "ask_about_shortcuts",
        MenuAction::AskAboutModels => "ask_about_models",
        MenuAction::AskAboutPrivacy => "ask_about_privacy",
        MenuAction::AskAboutTools => "ask_about_tools",
        MenuAction::MemoryInbox => "memory_inbox",
        MenuAction::RescueMode => "rescue_mode",
        MenuAction::Quit => "quit",
        MenuAction::TalkToggle => "talk_toggle",
        MenuAction::TalkStart => "talk_start",
        MenuAction::TalkStop => "talk_stop",
    })
}

fn action_from_id(id: &MenuId) -> Option<MenuAction> {
    match id.as_ref() {
        "settings" => Some(MenuAction::Settings),
        "settings_legacy" => Some(MenuAction::SettingsLegacy),
        "open_browser_data_panel" => Some(MenuAction::OpenBrowserDataPanel),
        "show_messages" => Some(MenuAction::ShowMessages),
        "reset_conversation" => Some(MenuAction::ResetConversation),
        "hide_fae" => Some(MenuAction::HideFae),
        "stop" => Some(MenuAction::Stop),
        "permissions_microphone" => Some(MenuAction::PermissionsMicrophone),
        "permissions_contacts" => Some(MenuAction::PermissionsContacts),
        "permissions_calendars" => Some(MenuAction::PermissionsCalendars),
        "permissions_reminders" => Some(MenuAction::PermissionsReminders),
        "permissions_mail_notes" => Some(MenuAction::PermissionsMailNotes),
        "open_privacy_security" => Some(MenuAction::OpenPrivacySecurity),
        "scheduler" => Some(MenuAction::Scheduler),
        "skills" => Some(MenuAction::Skills),
        "edit_soul" => Some(MenuAction::EditSoul),
        "edit_custom_instructions" => Some(MenuAction::EditCustomInstructions),
        "ask_fae" => Some(MenuAction::AskFae),
        "ask_about_shortcuts" => Some(MenuAction::AskAboutShortcuts),
        "ask_about_models" => Some(MenuAction::AskAboutModels),
        "ask_about_privacy" => Some(MenuAction::AskAboutPrivacy),
        "ask_about_tools" => Some(MenuAction::AskAboutTools),
        "memory_inbox" => Some(MenuAction::MemoryInbox),
        "rescue_mode" => Some(MenuAction::RescueMode),
        "quit" => Some(MenuAction::Quit),
        _ => None,
    }
}
