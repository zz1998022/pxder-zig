use super::{Action, KeyCode, KeyEvent, KeyModifiers, State};
use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};
use ratatui::layout::{Position, Rect};

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Target {
    Key(KeyCode),
    Input { focus: usize, cursor: usize },
    Toggle(usize),
    Source(KeyCode),
    Scroll,
}

/// Built from the same rectangles and display widths used to paint each frame.
/// Later regions take precedence (for example, input text over its border).
#[derive(Default)]
pub(super) struct HitMap(pub Vec<(Rect, Target)>);

impl HitMap {
    pub fn add(&mut self, area: Rect, target: Target) {
        if !area.is_empty() {
            self.0.push((area, target));
        }
    }

    pub fn at(&self, column: u16, row: u16) -> Option<Target> {
        self.0
            .iter()
            .rev()
            .find_map(|(area, target)| area.contains(Position::new(column, row)).then_some(*target))
    }
}

impl State {
    pub(super) fn mouse(&mut self, event: MouseEvent, hits: &HitMap) -> Action {
        let Some(target) = hits.at(event.column, event.row) else {
            return Action::None;
        };
        let key = match (event.kind, target) {
            (MouseEventKind::Down(MouseButton::Left), Target::Key(key)) => key,
            (MouseEventKind::Down(MouseButton::Left), Target::Input { focus, cursor }) => {
                self.selected = focus;
                self.cursor = cursor;
                return Action::None;
            }
            (MouseEventKind::Down(MouseButton::Left), Target::Toggle(focus)) => {
                self.selected = focus;
                KeyCode::Char(' ')
            }
            (MouseEventKind::Down(MouseButton::Left), Target::Source(key)) => {
                self.selected = 0;
                key
            }
            (MouseEventKind::ScrollUp, Target::Scroll) => KeyCode::Up,
            (MouseEventKind::ScrollDown, Target::Scroll) => KeyCode::Down,
            _ => return Action::None,
        };
        // Reuse keyboard actions, including busy-state guards and confirmations.
        self.key(KeyEvent::new(key, KeyModifiers::NONE))
    }
}
