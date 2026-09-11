use sysmon_core::mole::Decoder;

fn lines(name: &str) -> Vec<String> {
    let path = format!("{}/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(path).unwrap_or_default().lines().map(str::to_owned).collect()
}

#[test]
fn every_real_line_decodes() {
    let mut d = Decoder::new();
    let ls = lines("stream.ndjson");
    assert_eq!(ls.len(), 20);
    for (i, l) in ls.iter().enumerate() {
        let m = d.decode(l).unwrap_or_else(|e| panic!("line {i}: {e}"));
        assert!(m.health_score > 0 && m.health_score <= 100, "line {i} health {}", m.health_score);
        assert_eq!(m.cpu.per_core.len(), 8);
    }
    assert!(d.bad_keys().is_empty());
}

#[test]
fn first_fast_line_has_null_arrays_and_no_static_fields() {
    let mut d = Decoder::new();
    let m = d.decode(&lines("stream.ndjson")[0]).unwrap_or_default();
    assert!(m.top_processes.is_empty());
    assert!(m.gpu.is_empty());
    assert!(m.batteries.is_empty());
    assert_eq!(m.cpu.p_core_count, 0);
    assert_eq!(m.process_stale, None);
    let full = d.decode(&lines("stream.ndjson")[1]).unwrap_or_default();
    assert_eq!(full.cpu.p_core_count, 4);
    assert_eq!(full.cpu.e_core_count, 4);
    assert_eq!(full.process_stale, Some(false));
    assert_eq!(full.top_processes.len(), 5);
}

#[test]
fn degraded_lines_decode_or_skip_without_panic() {
    let ls = lines("degraded.ndjson");
    assert_eq!(ls.len(), 11);
    let mut d = Decoder::new();
    let r: Vec<_> = ls.iter().map(|l| d.decode(l)).collect();
    assert_eq!(r[0].as_ref().ok().and_then(|m| m.process_stale), Some(true));
    assert!(r[1].as_ref().ok().map(|m| m.gpu.is_empty()).unwrap_or(false));
    assert!(r[2].as_ref().ok().map(|m| m.gpu.is_empty() && m.top_processes.is_empty()).unwrap_or(false));
    assert_eq!(r[3].as_ref().ok().map(|m| m.thermal.cpu_temp), Some(0.0));
    assert_eq!(r[4].as_ref().ok().map(|m| m.memory.total), Some(0), "missing section takes its default");
    assert!(r[5].is_err(), "malformed JSON is skipped");
    let m6 = r[6].as_ref().ok().cloned().unwrap_or_default();
    assert_eq!(m6.thermal.cpu_temp, 0.0);
    assert!(m6.memory.total > 0, "other sections survive a bad one");
    assert!(d.bad_keys().contains(&"thermal".to_string()));
    let m7 = r[7].as_ref().ok().cloned().unwrap_or_default();
    assert!(m7.cpu.usage > 0.0, "bad value inside memory drops only memory");
    assert!(r[8].is_err());
    assert!(r[9].is_err());
    assert!(r[10].is_ok(), "unknown fields are ignored");
}

#[test]
fn local_penalties_reproduce_moles_health_score() {
    let mut d = Decoder::new();
    for (i, l) in lines("stream.ndjson").iter().enumerate() {
        let m = d.decode(l).unwrap_or_default();
        let p = sysmon_core::score::penalties(&m);
        let local = (100.0 - p.total()).clamp(0.0, 100.0) as i64;
        assert_eq!(local, m.health_score, "line {i}: local {local} vs mole {}", m.health_score);
    }
}
