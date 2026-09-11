use sysmon_core::panels::{parse, DEFAULT_TOML};

#[test]
fn defaults_parse() {
    let p = parse(DEFAULT_TOML);
    assert_eq!(p.error, None);
    assert_eq!(p.panels.len(), 7);
    assert_eq!(p.panels.iter().filter(|x| x.group == "system").count(), 4);
    assert_eq!(p.panels[4].metric, "energy");
    assert_eq!(p.panels[4].count, 5);
}

#[test]
fn syntax_error_reports_line() {
    let p = parse("[[panel]]\nmetric = \"cpu\"\n[[panel]]\nmetric = cpu\n");
    assert!(p.error.is_some());
    assert_eq!(p.line, Some(4));
    assert!(p.panels.is_empty());
}

#[test]
fn unknown_metric_names_the_panel() {
    let p = parse("[[panel]]\nmetric = \"cpu\"\n\n[[panel]]\nmetric = \"gpu\"\n");
    assert_eq!(p.error.as_deref(), Some("panel 2: unknown metric \"gpu\""));
    assert_eq!(p.line, Some(4));
    let ok = parse("[[panel]]\nmetric = \"memory\"\ngroup = \"app\"\ncount = 99\n");
    assert_eq!(ok.error, None);
    assert_eq!(ok.panels[0].count, 20);
    assert!(parse("").panels.is_empty());
    assert_eq!(parse("").error, None);
}
