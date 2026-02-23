use ratatui::style::Color;

#[derive(Clone, Copy)]
pub struct Theme {
    pub border: Color,
    pub text: Color,
    pub highlight: Color,
    pub header_bg: Color,
    pub header_fg: Color,
    pub status_bg: Color,
    pub status_fg: Color,
    pub input_text: Color,
    pub agent_text: Color,
    pub user_text: Color,
}

pub const DRACULA: Theme = Theme {
    border: Color::Rgb(98, 114, 164),
    text: Color::Rgb(248, 248, 242),
    highlight: Color::Rgb(189, 147, 249),
    header_bg: Color::Rgb(68, 71, 90),
    header_fg: Color::Rgb(139, 233, 253),
    status_bg: Color::Rgb(189, 147, 249),
    status_fg: Color::Rgb(40, 42, 54),
    input_text: Color::Rgb(241, 250, 140),
    agent_text: Color::Rgb(80, 250, 123),
    user_text: Color::Rgb(139, 233, 253),
};

pub const NORD: Theme = Theme {
    border: Color::Rgb(76, 86, 106),
    text: Color::Rgb(236, 239, 244),
    highlight: Color::Rgb(136, 192, 208),
    header_bg: Color::Rgb(59, 66, 82),
    header_fg: Color::Rgb(143, 188, 187),
    status_bg: Color::Rgb(129, 161, 193),
    status_fg: Color::Rgb(46, 52, 64),
    input_text: Color::Rgb(235, 203, 139),
    agent_text: Color::Rgb(163, 190, 140),
    user_text: Color::Rgb(136, 192, 208),
};

pub const DEFAULT: Theme = Theme {
    border: Color::DarkGray,
    text: Color::White,
    highlight: Color::Blue,
    header_bg: Color::Rgb(50, 50, 50),
    header_fg: Color::White,
    status_bg: Color::Blue,
    status_fg: Color::White,
    input_text: Color::Yellow,
    agent_text: Color::Green,
    user_text: Color::Cyan,
};
