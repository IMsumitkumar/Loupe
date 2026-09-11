use sysmon_core::mole::{Battery, Disk, MoleSnapshot};
use sysmon_core::score::{band, driver, penalties, pressure, verdict, Driver};

#[test]
fn bands_pin_moles_boundaries() {
    for (p, b) in [(0, "calm"), (15, "calm"), (16, "normal"), (35, "normal"), (36, "busy"), (55, "busy"), (56, "strained"), (100, "strained")] {
        assert_eq!(band(p), b, "pressure {p}");
    }
    assert_eq!(pressure(79), 21);
    assert_eq!(pressure(-5), 100);
    assert_eq!(pressure(140), 0);
}

#[test]
fn driver_is_the_largest_penalty() {
    let mut m = MoleSnapshot::default();
    m.cpu.usage = 13.0;
    m.memory.used_percent = 78.7;
    m.disks.push(Disk { used_percent: 94.8, ..Default::default() });
    let p = penalties(&m);
    assert_eq!(driver(&p), Driver::Disk);
    assert_eq!(p.issues, vec!["Disk Almost Full"]);
    m.memory.pressure = "critical".into();
    m.memory.used_percent = 92.0;
    assert_eq!(driver(&penalties(&m)), Driver::Memory);
    let calm = penalties(&MoleSnapshot::default());
    assert_eq!(driver(&calm), Driver::None);
    assert_eq!(calm.total(), 0.0);
}

#[test]
fn calm_and_flagged_verdicts_read_as_sentences() {
    let mut m = MoleSnapshot { health_score: 100, ..Default::default() };
    let v = verdict(Some(&m), &[]);
    assert_eq!(v.headline, "Nothing needs your attention");
    assert_eq!(v.explanation, "Every check passed. Nothing to explain.");
    assert!(!v.flagged);
    assert_eq!(v.band, "calm");

    m.health_score = 79;
    m.disks.push(Disk { used_percent: 94.8, used: 200, total: 228, ..Default::default() });
    let v = verdict(Some(&m), &[]);
    assert!(v.flagged);
    assert_eq!(v.driver, Driver::Disk);
    assert_eq!(v.headline, "Your disk is almost full");
    assert!(v.explanation.starts_with("95% of your disk is used"));
    assert_eq!(v.band, "normal");

    m.batteries.push(Battery { cycle_count: 950, capacity: 70, ..Default::default() });
    let p = penalties(&m);
    assert!(p.issues.contains(&"Battery Service Soon"));
    assert_eq!(p.battery, 5.0);

    let none = verdict(None, &[]);
    assert_eq!(none.band, "unknown");
    assert_eq!(none.score, None);
}
