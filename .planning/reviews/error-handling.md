# Error Handling Review
**Date**: Sun 15 Feb 2026 22:09:51 GMT

## Findings
- [CRITICAL] Found forbidden patterns in production code
src/bin/gui.rs:1097:            let latest_idx = html.find("Latest message").expect("latest message in HTML");
src/bin/gui.rs:1098:            let older_idx = html.find("Older message").expect("older message in HTML");
src/bin/gui.rs:1166:                let uri = cache.get(pose).expect("embedded pose missing");
src/bin/gui.rs:1182:                    .expect("clock")
src/bin/gui.rs:1186:            std::fs::create_dir_all(&dir).expect("create temp avatar dir");
src/bin/gui.rs:1187:            std::fs::write(dir.join("fae_base.png"), [0u8, 1u8, 2u8]).expect("write override pose");
src/bin/gui.rs:1272:                    .expect("clock")
src/bin/gui.rs:1277:            std::fs::create_dir_all(&nested).expect("create nested dirs");
src/bin/gui.rs:1278:            std::fs::write(root.join("a.txt"), "alpha").expect("write file a");
src/bin/gui.rs:1279:            std::fs::write(nested.join("b.txt"), "beta").expect("write file b");

## Grade: F
