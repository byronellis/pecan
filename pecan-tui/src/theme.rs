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
    pub user_bg: Color,
    pub user_fg: Color,
}

pub const DRACULA: Theme = Theme {
    border: Color::Rgb(98, 114, 164),
    text: Color::Rgb(248, 248, 242),
    highlight: Color::Rgb(189, 147, 249),
    header_bg: Color::Rgb(68, 71, 90),
    header_fg: Color::Rgb(139, 233, 253),
    status_bg: Color::Rgb(68, 71, 90),
    status_fg: Color::Rgb(189, 147, 249),
    input_text: Color::Rgb(241, 250, 140),
    agent_text: Color::Rgb(80, 250, 123),
    user_bg: Color::Rgb(68, 71, 90), // Subdued dark blue/gray
    user_fg: Color::Rgb(248, 248, 242),
};

pub const NORD: Theme = Theme {
    border: Color::Rgb(76, 86, 106),
    text: Color::Rgb(236, 239, 244),
    highlight: Color::Rgb(136, 192, 208),
    header_bg: Color::Rgb(59, 66, 82),
    header_fg: Color::Rgb(143, 188, 187),
    status_bg: Color::Rgb(59, 66, 82),
    status_fg: Color::Rgb(129, 161, 193),
    input_text: Color::Rgb(235, 203, 139),
    agent_text: Color::Rgb(163, 190, 140),
    user_bg: Color::Rgb(67, 76, 94), // Subdued Nord gray
    user_fg: Color::Rgb(236, 239, 244),
};

pub const DEFAULT: Theme = Theme {
    border: Color::DarkGray,
    text: Color::White,
    highlight: Color::Blue,
    header_bg: Color::Rgb(50, 50, 50),
    header_fg: Color::White,
    status_bg: Color::Rgb(50, 50, 50),
    status_fg: Color::Blue,
    input_text: Color::Yellow,
    agent_text: Color::White,
    user_bg: Color::Rgb(40, 40, 40),
    user_fg: Color::White,
};

pub const LIGHT: Theme = Theme {
    border: Color::Rgb(200, 200, 200),
    text: Color::Rgb(50, 50, 50),
    highlight: Color::Rgb(0, 100, 200),
    header_bg: Color::Rgb(240, 240, 240),
    header_fg: Color::Rgb(0, 0, 0),
    status_bg: Color::Rgb(230, 230, 230),
    status_fg: Color::Rgb(0, 100, 200),
    input_text: Color::Rgb(0, 0, 0), // Dark text for input
    agent_text: Color::Rgb(40, 120, 60), // Dark green for agent
    user_bg: Color::Rgb(235, 235, 235), // Light gray background for user
    user_fg: Color::Rgb(50, 50, 50), // Dark gray text for user
};
