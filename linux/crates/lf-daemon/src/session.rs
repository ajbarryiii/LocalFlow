//! Port of `Sources/ShortcutCore/DictationShortcutSessionController.swift`:
//! hold-to-talk versus tap-to-toggle.
//!
//! The control commands map to shortcut events as follows:
//! - `press` / `release`: hold key down / up (Hyprland `bind` / `bindr`);
//! - `toggle`: a complete tap of the toggle key (activated, then deactivated);
//! - `again` is the Paste Again shortcut, handled before this controller.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Hold,
    Toggle,
}

impl Mode {
    pub fn name(self) -> &'static str {
        match self {
            Mode::Hold => "hold",
            Mode::Toggle => "toggle",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    HoldActivated,
    HoldDeactivated,
    ToggleActivated,
    ToggleDeactivated,
    CopyAgainTriggered,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Start(Mode),
    Stop,
    SwitchedToToggle,
}

#[derive(Debug, Default)]
pub struct SessionController {
    active_mode: Option<Mode>,
    toggle_stop_armed: bool,
}

impl SessionController {
    pub fn active_mode(&self) -> Option<Mode> {
        self.active_mode
    }

    pub fn toggle_stop_armed(&self) -> bool {
        self.toggle_stop_armed
    }

    pub fn handle(&mut self, event: Event, is_transcribing: bool) -> Option<Action> {
        // Paste Again is handled before this controller runs; if it ever
        // reaches here, treat it as a no-op so dictation state is unaffected.
        if event == Event::CopyAgainTriggered {
            return None;
        }
        let Some(mode) = self.active_mode else {
            if is_transcribing {
                return None;
            }
            return match event {
                Event::ToggleActivated => {
                    self.active_mode = Some(Mode::Toggle);
                    self.toggle_stop_armed = false;
                    Some(Action::Start(Mode::Toggle))
                }
                Event::HoldActivated => {
                    self.active_mode = Some(Mode::Hold);
                    self.toggle_stop_armed = false;
                    Some(Action::Start(Mode::Hold))
                }
                Event::HoldDeactivated | Event::ToggleDeactivated | Event::CopyAgainTriggered => {
                    None
                }
            };
        };
        match (mode, event) {
            (Mode::Hold, Event::ToggleActivated) => {
                self.active_mode = Some(Mode::Toggle);
                self.toggle_stop_armed = false;
                Some(Action::SwitchedToToggle)
            }
            (Mode::Hold, Event::HoldDeactivated) => {
                self.reset();
                Some(Action::Stop)
            }
            (Mode::Toggle, Event::ToggleDeactivated) => {
                self.toggle_stop_armed = true;
                None
            }
            (Mode::Toggle, Event::ToggleActivated) => {
                if !self.toggle_stop_armed {
                    return None;
                }
                self.reset();
                Some(Action::Stop)
            }
            _ => None,
        }
    }

    pub fn begin_manual(&mut self, mode: Mode) {
        self.active_mode = Some(mode);
        self.toggle_stop_armed = false;
    }

    pub fn force_toggle_mode(&mut self) {
        self.active_mode = Some(Mode::Toggle);
        self.toggle_stop_armed = false;
    }

    pub fn reset(&mut self) {
        self.active_mode = None;
        self.toggle_stop_armed = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Ported from Tests/ShortcutCoreTests.swift.

    #[test]
    fn hold_session_controller_lifecycle() {
        let mut c = SessionController::default();
        assert_eq!(c.handle(Event::HoldActivated, true), None);
        assert_eq!(
            c.handle(Event::HoldActivated, false),
            Some(Action::Start(Mode::Hold))
        );
        assert_eq!(c.handle(Event::HoldDeactivated, false), Some(Action::Stop));
        assert_eq!(c.active_mode(), None);
    }

    #[test]
    fn toggle_session_controller_lifecycle() {
        let mut c = SessionController::default();
        assert_eq!(
            c.handle(Event::ToggleActivated, false),
            Some(Action::Start(Mode::Toggle))
        );
        assert_eq!(c.handle(Event::ToggleActivated, false), None);
        assert_eq!(c.handle(Event::ToggleDeactivated, false), None);
        assert!(c.toggle_stop_armed());
        assert_eq!(c.handle(Event::ToggleActivated, false), Some(Action::Stop));
        assert_eq!(c.active_mode(), None);
    }

    #[test]
    fn hold_to_toggle_session_controller_lifecycle() {
        let mut c = SessionController::default();
        assert_eq!(
            c.handle(Event::HoldActivated, false),
            Some(Action::Start(Mode::Hold))
        );
        assert_eq!(
            c.handle(Event::ToggleActivated, false),
            Some(Action::SwitchedToToggle)
        );
        assert_eq!(c.handle(Event::HoldDeactivated, false), None);
        assert_eq!(c.active_mode(), Some(Mode::Toggle));
        assert_eq!(c.handle(Event::CopyAgainTriggered, false), None);
        c.begin_manual(Mode::Hold);
        assert_eq!(c.active_mode(), Some(Mode::Hold));
        c.force_toggle_mode();
        assert_eq!(c.active_mode(), Some(Mode::Toggle));
        c.reset();
        assert_eq!(c.active_mode(), None);
        assert!(!c.toggle_stop_armed());
    }

    // Additional cases.

    #[test]
    fn releases_and_deactivations_without_a_session_do_nothing() {
        let mut c = SessionController::default();
        assert_eq!(c.handle(Event::HoldDeactivated, false), None);
        assert_eq!(c.handle(Event::ToggleDeactivated, false), None);
        assert_eq!(c.active_mode(), None);
    }

    #[test]
    fn toggle_mode_ignores_hold_events() {
        let mut c = SessionController::default();
        c.handle(Event::ToggleActivated, false);
        c.handle(Event::ToggleDeactivated, false);
        assert_eq!(c.handle(Event::HoldActivated, false), None);
        assert_eq!(c.handle(Event::HoldDeactivated, false), None);
        assert_eq!(c.active_mode(), Some(Mode::Toggle));
    }

    #[test]
    fn hold_mode_ignores_repeated_press() {
        let mut c = SessionController::default();
        c.handle(Event::HoldActivated, false);
        assert_eq!(c.handle(Event::HoldActivated, false), None);
        assert_eq!(c.handle(Event::ToggleDeactivated, false), None);
        assert_eq!(c.active_mode(), Some(Mode::Hold));
    }

    #[test]
    fn transcribing_only_blocks_new_sessions() {
        let mut c = SessionController::default();
        c.handle(Event::HoldActivated, false);
        // An active session still ends while a previous one transcribes.
        assert_eq!(c.handle(Event::HoldDeactivated, true), Some(Action::Stop));
        assert_eq!(c.handle(Event::ToggleActivated, true), None);
    }
}
