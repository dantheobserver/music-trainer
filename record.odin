package music_trainer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Records system audio via parecord from PulseAudio/PipeWire monitor source.

@(private = "file")
record_process: os.Process

@(private = "file")
record_path: string

get_monitor_source :: proc() -> string {
	result, stdout, _, err := os.process_exec(
		os.Process_Desc{
			command = {"pactl", "get-default-sink"},
		},
		context.temp_allocator,
	)
	if err != nil || result.exit_code != 0 do return ""
	sink := strings.trim_space(string(stdout))
	if len(sink) == 0 do return ""
	return strings.concatenate({sink, ".monitor"}, context.temp_allocator)
}

start_recording :: proc(state: ^App_State) {
	if state.is_recording do return

	monitor := get_monitor_source()
	if len(monitor) == 0 {
		state.download_status = "No audio monitor source found"
		return
	}

	dir := get_download_dir()
	now := time.now()
	y, mon, d := time.date(now)
	h, m, s := time.clock(now)
	filename := fmt.tprintf("recording_%04d%02d%02d_%02d%02d%02d.wav", y, int(mon), d, h, m, s)

	device_arg := strings.concatenate({"--device=", monitor})
	record_path = strings.concatenate({dir, "/", filename})

	proc_or_err, start_err := os.process_start({
		command = {
			"parecord",
			device_arg,
			"--format=s16le",
			"--rate=48000",
			"--channels=2",
			"--file-format=wav",
			record_path,
		},
	})

	if start_err != nil {
		state.download_status = "Failed to start recording"
		fmt.eprintfln("parecord start error: %v", start_err)
		return
	}

	record_process = proc_or_err
	state.is_recording = true
	state.record_file = record_path
	state.download_status = "Recording system audio..."
}

stop_recording :: proc(state: ^App_State) {
	if !state.is_recording do return

	state.is_recording = false

	term_err := os.process_terminate(record_process)
	if term_err != nil {
		fmt.eprintfln("Failed to stop parecord: %v", term_err)
		_ = os.process_kill(record_process)
	}
	_, _ = os.process_wait(record_process)

	state.download_status = fmt.ctprintf("Saved: %s", record_path)
	scan_library(state)
}
