use muda::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    Settings,
    SettingsLegacy,
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
    /// Single "Ask Fae for Help" item that injects a canned discovery prompt.
    /// Replaces the four "Ask About …" items removed in UX W5.
    AskFaeForHelp,
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
            MenuAction::AskFaeForHelp => "ask_fae_for_help",
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
    /// Build the orb context menu.
    ///
    /// `advanced` — when true, appends the engineering section (Scheduler,
    /// Skills, Edit Soul/Instructions, Settings legacy, permissions ×6, Memory
    /// Inbox). Reads `FAE_ORB_ADVANCED_MENUS=1` at launch; applies at next
    /// launch after the Settings toggle changes.
    ///
    /// `fleet` — non-empty list of x0x owner-fleet agent IDs causes a "Hand
    /// off to…" submenu to appear. Items emit `handoff_<agentId>` via the raw
    /// event path (bypasses `MenuAction` — handled in main.rs event loop).
    pub fn new(advanced: bool, fleet: &[String]) -> Result<Self, muda::Error> {
        let menu = Menu::new();

        // ── Primary actions ──────────────────────────────────────────────────
        // Right ⌥ hold-to-talk is the primary gesture; this item is the
        // discoverable mouse fallback (capture ends on pause or via Stop).
        append_item(&menu, MenuAction::TalkToggle, "Talk to Fae")?;
        append_item(&menu, MenuAction::Settings, "Settings\u{2026}")?;
        append_separator(&menu)?;

        // Hand off to… — only when an owner fleet is configured.
        if !fleet.is_empty() {
            let handoff_sub = Submenu::new("Hand off to\u{2026}", true);
            for agent_id in fleet {
                let short = format!("{}\u{2026}", agent_id.chars().take(12).collect::<String>());
                let item_id = format!("handoff_{agent_id}");
                handoff_sub.append(&MenuItem::with_id(
                    MenuId::new(&item_id),
                    &short,
                    true,
                    None,
                ))?;
            }
            menu.append(&handoff_sub)?;
        }

        append_item(&menu, MenuAction::ResetConversation, "Reset Conversation")?;
        append_item(&menu, MenuAction::HideFae, "Hide Fae")?;
        append_item(&menu, MenuAction::Stop, "Stop")?;
        append_separator(&menu)?;
        append_item(&menu, MenuAction::AskFaeForHelp, "Ask Fae for Help")?;
        append_item(&menu, MenuAction::RescueMode, "Rescue Mode\u{2026}")?;
        append_separator(&menu)?;
        append_item(&menu, MenuAction::Quit, "Quit Fae")?;

        // ── Engineering section (Advanced menus ON) ──────────────────────────
        if advanced {
            append_separator(&menu)?;
            append_item(&menu, MenuAction::Scheduler, "Scheduler")?;
            append_item(&menu, MenuAction::Skills, "Skills")?;
            append_item(&menu, MenuAction::EditSoul, "Edit Soul\u{2026}")?;
            append_item(
                &menu,
                MenuAction::EditCustomInstructions,
                "Edit Custom Instructions\u{2026}",
            )?;
            append_item(
                &menu,
                MenuAction::SettingsLegacy,
                "Settings (legacy)\u{2026}",
            )?;
            append_separator(&menu)?;
            append_item(
                &menu,
                MenuAction::PermissionsMicrophone,
                "Microphone \u{2014} Check Permission",
            )?;
            append_item(
                &menu,
                MenuAction::PermissionsContacts,
                "Contacts \u{2014} Check Permission",
            )?;
            append_item(
                &menu,
                MenuAction::PermissionsCalendars,
                "Calendars \u{2014} Check Permission",
            )?;
            append_item(
                &menu,
                MenuAction::PermissionsReminders,
                "Reminders \u{2014} Check Permission",
            )?;
            append_item(
                &menu,
                MenuAction::PermissionsMailNotes,
                "Mail & Notes (Automation)\u{2026}",
            )?;
            append_item(
                &menu,
                MenuAction::OpenPrivacySecurity,
                "Open Privacy & Security\u{2026}",
            )?;
            append_separator(&menu)?;
            append_item(&menu, MenuAction::MemoryInbox, "Memory Inbox\u{2026}")?;
        }

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
        MenuAction::AskFaeForHelp => "ask_fae_for_help",
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
        "ask_fae_for_help" => Some(MenuAction::AskFaeForHelp),
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
