//! `panels.toml`: the one extension point. Swift owns the file; this module
//! only turns its text into a validated panel list (or an error with a line).

use serde::{Deserialize, Serialize};

pub const DEFAULT_TOML: &str = r#"# Loupe panels. Overview shows the "system" panels as tiles (first four);
# Apps offers the "app" and "process" panels as metric choices.
#
# metric = cpu | memory | energy | disk | network | power | battery | thermal | disk_io
# group  = app | process | system
# sort   = desc | asc
# count  = rows, 1..20, ignored when group = "system"
# chart  = sparkline | bar | none
# label  = optional override

[[panel]]
metric = "cpu"
group  = "system"
chart  = "bar"

[[panel]]
metric = "memory"
group  = "system"
chart  = "sparkline"

[[panel]]
metric = "disk"
group  = "system"
chart  = "none"

[[panel]]
metric = "network"
group  = "system"
chart  = "sparkline"

[[panel]]
metric = "energy"
group  = "app"
count  = 5
chart  = "bar"

[[panel]]
metric = "memory"
group  = "app"
count  = 5
chart  = "bar"

[[panel]]
metric = "cpu"
group  = "app"
count  = 5
chart  = "bar"
"#;

pub const METRICS: [&str; 9] = [
    "cpu", "memory", "energy", "disk", "network", "power", "battery", "thermal", "disk_io",
];
pub const GROUPS: [&str; 3] = ["app", "process", "system"];
pub const SORTS: [&str; 2] = ["desc", "asc"];
pub const CHARTS: [&str; 3] = ["sparkline", "bar", "none"];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Panel {
    pub metric: String,
    pub group: String,
    pub sort: String,
    pub count: u32,
    pub chart: String,
    pub label: Option<String>,
}

impl Default for Panel {
    fn default() -> Self {
        Self {
            metric: "cpu".into(),
            group: "system".into(),
            sort: "desc".into(),
            count: 5,
            chart: "sparkline".into(),
            label: None,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
struct File {
    #[serde(default)]
    panel: Vec<Panel>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Parsed {
    pub panels: Vec<Panel>,
    pub error: Option<String>,
    pub line: Option<usize>,
    pub default_toml: &'static str,
}

fn line_of_offset(text: &str, offset: usize) -> usize {
    text.get(..offset).map(|s| s.matches('\n').count() + 1).unwrap_or(1)
}

fn line_of_panel(text: &str, index: usize) -> Option<usize> {
    text.lines()
        .enumerate()
        .filter(|(_, l)| l.trim() == "[[panel]]")
        .nth(index)
        .map(|(i, _)| i + 1)
}

pub fn parse(text: &str) -> Parsed {
    let file: File = match toml::from_str(text) {
        Ok(f) => f,
        Err(e) => {
            return Parsed {
                panels: Vec::new(),
                error: Some(e.message().to_string()),
                line: e.span().map(|s| line_of_offset(text, s.start)),
                default_toml: DEFAULT_TOML,
            }
        }
    };
    let mut panels = file.panel;
    for (i, p) in panels.iter_mut().enumerate() {
        let bad = if !METRICS.contains(&p.metric.as_str()) {
            Some(format!("unknown metric \"{}\"", p.metric))
        } else if !GROUPS.contains(&p.group.as_str()) {
            Some(format!("unknown group \"{}\"", p.group))
        } else if !SORTS.contains(&p.sort.as_str()) {
            Some(format!("unknown sort \"{}\"", p.sort))
        } else if !CHARTS.contains(&p.chart.as_str()) {
            Some(format!("unknown chart \"{}\"", p.chart))
        } else {
            None
        };
        if let Some(msg) = bad {
            return Parsed {
                panels: Vec::new(),
                error: Some(format!("panel {}: {msg}", i + 1)),
                line: line_of_panel(text, i),
                default_toml: DEFAULT_TOML,
            };
        }
        p.count = p.count.clamp(1, 20);
    }
    Parsed { panels, error: None, line: None, default_toml: DEFAULT_TOML }
}

pub fn parse_json(text: &str) -> String {
    serde_json::to_string(&parse(text)).unwrap_or_else(|_| "{\"panels\":[]}".to_string())
}
