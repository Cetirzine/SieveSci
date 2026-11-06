// SieveSci desktop shell. The agent runs in `sievesci serve` (docs/SERVE_PROTOCOL.md); this process
// only starts it and relays its JSON lines to and from the web UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Default)]
struct Serve {
    /// Each start is a new generation; the UI ignores lines from older ones.
    gen: u64,
    child: Option<Child>,
    stdin: Option<ChildStdin>,
}

struct ServeState(Mutex<Serve>);

#[derive(Clone, serde::Serialize)]
struct LinePayload { gen: u64, line: String }

#[derive(Clone, serde::Serialize)]
struct ExitPayload { gen: u64, reason: String }

/// SIEVESCI_BIN, else the engine bundled in the app's resources (`engine/sievesci`, with its resource
/// bundle and, on Windows, the Swift runtime beside it), else the CLI next to this executable, else
/// `sievesci` on PATH (development).
fn sievesci_binary(app: &AppHandle) -> PathBuf {
    if let Some(p) = std::env::var_os("SIEVESCI_BIN") {
        return PathBuf::from(p);
    }
    let name = if cfg!(windows) { "sievesci.exe" } else { "sievesci" };
    if let Ok(res) = app.path().resource_dir() {
        let bundled = res.join("engine").join(name);
        if bundled.is_file() {
            return bundled;
        }
    }
    if let Some(dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf())) {
        let beside = dir.join(name);
        if beside.is_file() {
            return beside;
        }
    }
    PathBuf::from(name)
}

/// Model and mode options for serve until the UI has settings, e.g. "--provider deepseek --model deepseek-flash".
fn extra_args() -> Vec<String> {
    std::env::var("SIEVESCI_SERVE_ARGS").map(|s| s.split_whitespace().map(String::from).collect()).unwrap_or_default()
}

/// Closing stdin makes serve shut down cleanly; it is killed if it has not exited after 5 s.
fn stop_locked(s: &mut Serve) {
    s.stdin = None;
    if let Some(mut child) = s.child.take() {
        std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                if let Ok(Some(_)) = child.try_wait() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            let _ = child.kill();
            let _ = child.wait();
        });
    }
}

#[tauri::command]
fn serve_start(app: AppHandle, state: State<ServeState>, workspace: Option<String>) -> Result<u64, String> {
    let mut s = state.0.lock().map_err(|e| e.to_string())?;
    stop_locked(&mut s);
    s.gen += 1;
    let gen = s.gen;
    let bin = sievesci_binary(&app);
    let mut cmd = Command::new(&bin);
    cmd.arg("serve");
    // Without a workspace serve starts on the saved configuration; the UI opens folders itself.
    if let Some(ws) = workspace.filter(|w| !w.is_empty()) { cmd.arg("--workspace").arg(ws); }
    cmd.args(extra_args())
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console flashes up for the child
    }
    let mut child = cmd.spawn().map_err(|e| format!("cannot start sievesci ({}): {e}", bin.display()))?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    s.stdin = child.stdin.take();
    s.child = Some(child);
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(line) => { let _ = app.emit("serve-line", LinePayload { gen, line }); }
                Err(_) => break,
            }
        }
        let _ = app.emit("serve-exit", ExitPayload { gen, reason: "sievesci serve exited".into() });
    });
    Ok(gen)
}

#[tauri::command]
fn serve_send(state: State<ServeState>, gen: u64, line: String) -> Result<(), String> {
    let mut s = state.0.lock().map_err(|e| e.to_string())?;
    if s.gen != gen {
        return Err("this connection was replaced".into());
    }
    let stdin = s.stdin.as_mut().ok_or("sievesci serve is not running")?;
    let one_line = line.replace('\n', " ");
    stdin.write_all(one_line.as_bytes()).and_then(|_| stdin.write_all(b"\n")).and_then(|_| stdin.flush()).map_err(|e| e.to_string())
}

#[tauri::command]
fn serve_stop(state: State<ServeState>, gen: u64) {
    if let Ok(mut s) = state.0.lock() {
        if s.gen == gen {
            stop_locked(&mut s);
        }
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_notification::init())
        .manage(ServeState(Mutex::new(Serve::default())))
        .invoke_handler(tauri::generate_handler![serve_start, serve_send, serve_stop])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Destroyed = event {
                if let Ok(mut s) = window.state::<ServeState>().0.lock() {
                    stop_locked(&mut s);
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running SieveSci");
}
