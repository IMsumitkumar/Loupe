use sysmon_core::history::{push, History, CAPACITY};

#[test]
fn ring_keeps_the_newest_300() {
    let mut h = History::default();
    for i in 0..400 {
        push(&mut h.cpu, Some(i as f32));
    }
    assert_eq!(h.cpu.len(), CAPACITY);
    assert_eq!(h.cpu.front().copied().flatten(), Some(100.0));
    assert_eq!(h.cpu.back().copied().flatten(), Some(399.0));
    push(&mut h.cpu, Some(f32::NAN));
    assert_eq!(h.cpu.back().copied(), Some(None));
    push(&mut h.cpu, Some(41.2345));
    assert_eq!(h.cpu.back().copied().flatten(), Some(41.2));
    h.clear();
    assert!(h.cpu.is_empty());
}
