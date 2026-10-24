// The functions the launcher's Dart code calls (lib/core/audio/atrac9.dart), exported from the
// shared library hook/build.dart builds around LibAtrac9.
#include "libatrac9.h"

#if defined(_WIN32)
#define ANYPS5_EXPORT __declspec(dllexport)
#else
#define ANYPS5_EXPORT __attribute__((visibility("default")))
#endif

// A decoder for the four config bytes of an ATRAC9 file's format chunk, or NULL when they are not
// usable. info gets channels, frame samples and frames per superframe.
ANYPS5_EXPORT void* anyps5_atrac9_open(unsigned char* config, int* info)
{
	void* handle = Atrac9GetHandle();
	if (!handle) return 0;
	Atrac9CodecInfo codec;
	if (Atrac9InitDecoder(handle, config) != 0 || Atrac9GetCodecInfo(handle, &codec) != 0) {
		Atrac9ReleaseHandle(handle);
		return 0;
	}
	info[0] = codec.channels;
	info[1] = codec.frameSamples;
	info[2] = codec.framesInSuperframe;
	return handle;
}

// One frame to interleaved floats; used gets the bytes it took. 0 when it decoded.
ANYPS5_EXPORT int anyps5_atrac9_decode(void* handle, const unsigned char* data, int size, float* pcm, int* used)
{
	return Atrac9DecodeF32(handle, data, size, pcm, used, 0);
}

ANYPS5_EXPORT void anyps5_atrac9_close(void* handle)
{
	Atrac9ReleaseHandle(handle);
}
