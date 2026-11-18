//! tvOS C ABI. The UI owns one handle per playback session and serializes calls on the main thread.
use aiostreams_container::Options;
use aiostreams_thumbs::{Event, Settings, Thumbnails};
use std::{ffi::{CStr, c_char}, sync::{Arc, Mutex}, time::Duration};

pub struct Handle { engine: Thumbnails, inbox: Arc<Mutex<Option<Event>>> }

/// URL and optional JSON dictionary of HTTP headers are borrowed only during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_open(url: *const c_char, headers: *const c_char, width: u32) -> *mut Handle {
    if url.is_null() || !(64..=2048).contains(&width) { return std::ptr::null_mut(); }
    let Ok(url) = (unsafe { CStr::from_ptr(url) }).to_str() else { return std::ptr::null_mut(); };
    let pairs = if headers.is_null() { Vec::new() } else {
        let Ok(s) = (unsafe { CStr::from_ptr(headers) }).to_str() else { return std::ptr::null_mut(); };
        let Ok(map) = serde_json::from_str::<std::collections::BTreeMap<String,String>>(s) else { return std::ptr::null_mut(); };
        map.into_iter().collect()
    };
    let inbox = Arc::new(Mutex::new(None));
    let out = inbox.clone();
    let engine = Thumbnails::new(url, Options { headers: pairs, timeout: Duration::from_secs(10), connect_timeout: Duration::from_secs(5), ..Options::default() }, Settings { width: width as usize, ..Settings::default() }, move |e| { if let Ok(mut p) = out.lock() { *p = Some(e); } });
    Box::into_raw(Box::new(Handle { engine, inbox }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_prepare(h: *mut Handle) { if let Some(h) = unsafe { h.as_ref() } { h.engine.prepare(); } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_want(h: *mut Handle, ms: u64) { if let Some(h) = unsafe { h.as_ref() } { h.engine.want(ms, None); } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_keyframe(h: *mut Handle, ms: u64) -> i64 { unsafe { h.as_ref() }.and_then(|h| h.engine.keyframe_at(ms)).and_then(|v| i64::try_from(v).ok()).unwrap_or(-1) }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_clear(h: *mut Handle) { if let Some(h) = unsafe { h.as_ref() } { h.engine.clear(); if let Ok(mut p) = h.inbox.lock() { *p = None; } } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_take(h: *mut Handle) -> *mut Event { unsafe { h.as_ref() }.and_then(|h| h.inbox.lock().ok()?.take()).map(|e| Box::into_raw(Box::new(e))).unwrap_or(std::ptr::null_mut()) }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_event_time(e: *const Event) -> i64 { match unsafe { e.as_ref() } { Some(Event::Thumbnail(t)) => i64::try_from(t.time_ms).unwrap_or(-1), _ => -1 } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_event_data(e: *const Event, n: *mut usize) -> *const u8 { if n.is_null() { return std::ptr::null(); } unsafe { *n = 0; } if let Some(Event::Thumbnail(t)) = unsafe { e.as_ref() } { unsafe { *n = t.jpeg.len(); } t.jpeg.as_ptr() } else { std::ptr::null() } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_event_free(e: *mut Event) { if !e.is_null() { drop(unsafe { Box::from_raw(e) }); } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nvthumb_close(h: *mut Handle) { if !h.is_null() { drop(unsafe { Box::from_raw(h) }); } }
