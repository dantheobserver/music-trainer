package music_trainer

import "core:math"
import "core:math/cmplx"

hann_window :: proc(samples: []f32, output: []f32) {
	n := len(samples)
	for i in 0 ..< n {
		multiplier := f32(0.5 * (1.0 - math.cos(math.TAU * f64(i) / f64(n - 1))))
		output[i] = samples[i] * multiplier
	}
}

fft :: proc(buf: []complex128) {
	n := len(buf)
	if n <= 1 do return

	// Bit-reversal permutation
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j >= bit {
			j -= bit
			bit >>= 1
		}
		j += bit
		if i < j {
			buf[i], buf[j] = buf[j], buf[i]
		}
	}

	// Butterfly stages
	length := 2
	for length <= n {
		angle := -math.TAU / f64(length)
		wn := cmplx.exp(complex(0.0, angle))

		for start := 0; start < n; start += length {
			w: complex128 = 1.0
			half := length / 2
			for k in 0 ..< half {
				t := w * buf[start + k + half]
				u := buf[start + k]
				buf[start + k] = u + t
				buf[start + k + half] = u - t
				w *= wn
			}
		}
		length *= 2
	}
}

magnitude_spectrum :: proc(fft_result: []complex128, out: []f64) {
	n := len(out)
	for i in 0 ..< n {
		out[i] = cmplx.abs(fft_result[i])
	}
}

bin_to_frequency :: proc(bin: f64, sample_rate: u32, fft_size: int) -> f64 {
	return bin * f64(sample_rate) / f64(fft_size)
}

frequency_to_bin :: proc(freq: f64, sample_rate: u32, fft_size: int) -> int {
	return int(freq * f64(fft_size) / f64(sample_rate))
}
