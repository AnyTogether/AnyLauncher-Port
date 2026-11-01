// The game's sound on Windows, for Remote Play, broadcasting and clips (lib/core/capture/
// game_sound.dart): WASAPI loopback, as 16-bit stereo at 48 kHz in a ring the launcher reads.
//
// First the game's own process tree (process loopback, Windows 10 build 20348 and Windows 11):
// only what the game plays, never the launcher's sounds or a voice call. Where Windows has no
// process loopback, the whole output device (endpoint loopback) when the caller allows it.
// On Linux and macOS every call says there is nothing: those use PulseAudio's tools instead.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define ANYPS5_EXPORT __declspec(dllexport)
#else
#define ANYPS5_EXPORT __attribute__((visibility("default")))
#endif

// States anyps5_sound_state gives.
#define SOUND_STARTING 0
#define SOUND_GAME 1
#define SOUND_SYSTEM 2
#define SOUND_FAILED -1

#if defined(_WIN32)

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

#pragma comment(lib, "ole32.lib")

// The GUIDs used, written out so no import library or newer SDK header is needed.
static const GUID kIUnknown = {0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID kIAgileObject = {0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}};
static const GUID kICompletionHandler = {0x41d949ab, 0x9862, 0x444a, {0x80, 0xf6, 0xc2, 0x61, 0x33, 0x4d, 0xa5, 0xeb}};
static const GUID kIAudioClient = {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};
static const GUID kIAudioCaptureClient = {0xc8adbd64, 0xe71e, 0x48a0, {0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17}};
static const GUID kMMDeviceEnumerator = {0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID kIMMDeviceEnumerator = {0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID kSubtypeFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID kSubtypePcm = {0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

static int same_guid(const GUID *a, const GUID *b) { return memcmp(a, b, sizeof(GUID)) == 0; }

// AUDIOCLIENT_ACTIVATION_PARAMS for AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK (1) with
// PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE (0).
typedef struct {
  DWORD activation_type;
  DWORD target_process;
  DWORD loopback_mode;
} LoopbackParams;

// IActivateAudioInterfaceAsyncOperation and the completion handler, as C vtables.
typedef struct AsyncOperation AsyncOperation;
typedef struct {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(AsyncOperation *, const IID *, void **);
  ULONG(STDMETHODCALLTYPE *AddRef)(AsyncOperation *);
  ULONG(STDMETHODCALLTYPE *Release)(AsyncOperation *);
  HRESULT(STDMETHODCALLTYPE *GetActivateResult)(AsyncOperation *, HRESULT *, IUnknown **);
} AsyncOperationVtbl;
struct AsyncOperation {
  const AsyncOperationVtbl *lpVtbl;
};

typedef struct Handler Handler;
typedef struct {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(Handler *, const IID *, void **);
  ULONG(STDMETHODCALLTYPE *AddRef)(Handler *);
  ULONG(STDMETHODCALLTYPE *Release)(Handler *);
  HRESULT(STDMETHODCALLTYPE *ActivateCompleted)(Handler *, AsyncOperation *);
} HandlerVtbl;
struct Handler {
  const HandlerVtbl *lpVtbl;
  volatile LONG references;
  HANDLE done;
  HRESULT result;
  IAudioClient *client;
};

static HRESULT STDMETHODCALLTYPE handler_query(Handler *self, const IID *id, void **out) {
  // IAgileObject has no methods of its own: the same pointer answers it. Without it Windows
  // refuses the handler (E_ILLEGAL_METHOD_CALL).
  if (same_guid(id, &kIUnknown) || same_guid(id, &kICompletionHandler) || same_guid(id, &kIAgileObject)) {
    *out = self;
    InterlockedIncrement(&self->references);
    return S_OK;
  }
  *out = NULL;
  return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE handler_add(Handler *self) { return (ULONG)InterlockedIncrement(&self->references); }

static ULONG STDMETHODCALLTYPE handler_release(Handler *self) {
  LONG left = InterlockedDecrement(&self->references);
  if (left == 0) {
    if (self->client) IAudioClient_Release(self->client);
    CloseHandle(self->done);
    free(self);
  }
  return (ULONG)left;
}

static HRESULT STDMETHODCALLTYPE handler_completed(Handler *self, AsyncOperation *operation) {
  HRESULT result = E_FAIL;
  IUnknown *unknown = NULL;
  HRESULT asked = operation->lpVtbl->GetActivateResult(operation, &result, &unknown);
  if (SUCCEEDED(asked) && SUCCEEDED(result) && unknown) {
    result = IUnknown_QueryInterface(unknown, &kIAudioClient, (void **)&self->client);
  } else if (SUCCEEDED(result)) {
    result = FAILED(asked) ? asked : E_FAIL;
  }
  if (unknown) IUnknown_Release(unknown);
  self->result = result;
  SetEvent(self->done);
  return S_OK;
}

static const HandlerVtbl kHandlerVtbl = {handler_query, handler_add, handler_release, handler_completed};

typedef HRESULT(WINAPI *ActivateAsync)(LPCWSTR, const IID *, PROPVARIANT *, Handler *, AsyncOperation **);

// The game's process tree as an audio client, or NULL where Windows has no process loopback.
static IAudioClient *process_client(DWORD pid) {
  HMODULE library = LoadLibraryW(L"Mmdevapi.dll");
  if (!library) return NULL;
  ActivateAsync activate = (ActivateAsync)(void *)GetProcAddress(library, "ActivateAudioInterfaceAsync");
  if (!activate) return NULL;
  Handler *handler = (Handler *)calloc(1, sizeof(Handler));
  if (!handler) return NULL;
  handler->lpVtbl = &kHandlerVtbl;
  handler->references = 1;
  handler->done = CreateEventW(NULL, TRUE, FALSE, NULL);
  handler->result = E_FAIL;
  LoopbackParams params = {1, pid, 0};
  PROPVARIANT variant;
  memset(&variant, 0, sizeof(variant));
  variant.vt = VT_BLOB;
  variant.blob.cbSize = sizeof(params);
  variant.blob.pBlobData = (BYTE *)&params;
  AsyncOperation *operation = NULL;
  IAudioClient *client = NULL;
  HRESULT started = activate(L"VAD\\Process_Loopback", &kIAudioClient, &variant, handler, &operation);
  if (SUCCEEDED(started) && WaitForSingleObject(handler->done, 3000) == WAIT_OBJECT_0 && SUCCEEDED(handler->result)) {
    client = handler->client;
    handler->client = NULL;
  }
  if (operation) operation->lpVtbl->Release(operation);
  handler_release(handler);
  return client;
}

// What the launcher reads: 16-bit stereo at 48 kHz.
#define RATE 48000
#define RING_BYTES (RATE * 4)

typedef struct {
  CRITICAL_SECTION lock;
  uint8_t ring[RING_BYTES];
  int head;  // where the next byte is written
  int count; // bytes waiting
  volatile LONG state;
  volatile LONG stop;
  HANDLE thread;
  DWORD pid;
  int allow_system;
  // Converting a device's own format (endpoint loopback where Windows will not convert).
  int channels;
  int bits;
  int is_float;
  int rate;
  double position; // between the previous frame and the next, for the resampler
  float previous[2];
} Sound;

static void ring_put(Sound *sound, const uint8_t *bytes, int length) {
  EnterCriticalSection(&sound->lock);
  if (length > RING_BYTES) {
    bytes += length - RING_BYTES;
    length = RING_BYTES;
  }
  for (int index = 0; index < length; index++) {
    sound->ring[sound->head] = bytes[index];
    sound->head = (sound->head + 1) % RING_BYTES;
  }
  sound->count += length;
  // Nobody read for a second: the oldest goes.
  if (sound->count > RING_BYTES) sound->count = RING_BYTES;
  LeaveCriticalSection(&sound->lock);
}

static int16_t to16(float value) {
  if (value > 1.0f) value = 1.0f;
  if (value < -1.0f) value = -1.0f;
  return (int16_t)(value * 32767.0f);
}

// One frame of the device's format as two floats.
static void frame_of(Sound *sound, const uint8_t *frame, float out[2]) {
  for (int channel = 0; channel < 2; channel++) {
    int source = channel < sound->channels ? channel : 0;
    float value = 0;
    if (sound->is_float && sound->bits == 32) {
      value = ((const float *)frame)[source];
    } else if (sound->bits == 16) {
      value = ((const int16_t *)frame)[source] / 32768.0f;
    } else if (sound->bits == 32) {
      value = (float)(((const int32_t *)frame)[source] / 2147483648.0);
    } else if (sound->bits == 24) {
      const uint8_t *bytes = frame + source * 3;
      int32_t sample = (int32_t)((uint32_t)bytes[0] << 8 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 24);
      value = (float)(sample / 2147483648.0);
    }
    out[channel] = value;
  }
}

// The device's frames as 16-bit stereo at 48 kHz, by straight-line resampling.
static void convert(Sound *sound, const uint8_t *data, UINT32 frames, int silent) {
  int stride = sound->channels * sound->bits / 8;
  double step = (double)sound->rate / RATE;
  int16_t out[512];
  int filled = 0;
  for (UINT32 index = 0; index < frames; index++) {
    float current[2] = {0, 0};
    if (!silent) frame_of(sound, data + (size_t)index * stride, current);
    while (sound->position < 1.0) {
      double t = sound->position;
      out[filled++] = to16((float)(sound->previous[0] + (current[0] - sound->previous[0]) * t));
      out[filled++] = to16((float)(sound->previous[1] + (current[1] - sound->previous[1]) * t));
      if (filled == 512) {
        ring_put(sound, (const uint8_t *)out, filled * 2);
        filled = 0;
      }
      sound->position += step;
    }
    sound->position -= 1.0;
    sound->previous[0] = current[0];
    sound->previous[1] = current[1];
  }
  if (filled) ring_put(sound, (const uint8_t *)out, filled * 2);
}

static void fill_format(WAVEFORMATEX *format) {
  memset(format, 0, sizeof(*format));
  format->wFormatTag = 1; // WAVE_FORMAT_PCM
  format->nChannels = 2;
  format->nSamplesPerSec = RATE;
  format->wBitsPerSample = 16;
  format->nBlockAlign = 4;
  format->nAvgBytesPerSec = RATE * 4;
}

// AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY.
#define CONVERT_FLAGS (0x80000000 | 0x08000000)

// The output device as an audio client, initialised: in our format when Windows converts,
// else in its own (and `sound` set up to convert).
static IAudioClient *system_client(Sound *sound, HANDLE event, int *converted, int *evented) {
  IMMDeviceEnumerator *enumerator = NULL;
  IMMDevice *device = NULL;
  IAudioClient *client = NULL;
  if (FAILED(CoCreateInstance(&kMMDeviceEnumerator, NULL, CLSCTX_ALL, &kIMMDeviceEnumerator, (void **)&enumerator))) return NULL;
  if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device))) {
    IMMDeviceEnumerator_Release(enumerator);
    return NULL;
  }
  IMMDeviceEnumerator_Release(enumerator);
  HRESULT made = IMMDevice_Activate(device, &kIAudioClient, CLSCTX_ALL, NULL, (void **)&client);
  IMMDevice_Release(device);
  if (FAILED(made)) return NULL;
  WAVEFORMATEX format;
  fill_format(&format);
  DWORD loopback = AUDCLNT_STREAMFLAGS_LOOPBACK;
  if (SUCCEEDED(IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, loopback | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | CONVERT_FLAGS, 2000000, 0, &format, NULL))) {
    *converted = 1;
    *evented = SUCCEEDED(IAudioClient_SetEventHandle(client, event));
    return client;
  }
  // A client is initialised once: a fresh one for the device's own format.
  IAudioClient_Release(client);
  client = NULL;
  if (FAILED(CoCreateInstance(&kMMDeviceEnumerator, NULL, CLSCTX_ALL, &kIMMDeviceEnumerator, (void **)&enumerator))) return NULL;
  made = IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device);
  IMMDeviceEnumerator_Release(enumerator);
  if (FAILED(made)) return NULL;
  made = IMMDevice_Activate(device, &kIAudioClient, CLSCTX_ALL, NULL, (void **)&client);
  IMMDevice_Release(device);
  if (FAILED(made)) return NULL;
  WAVEFORMATEX *mix = NULL;
  if (FAILED(IAudioClient_GetMixFormat(client, &mix)) || !mix) {
    IAudioClient_Release(client);
    return NULL;
  }
  sound->channels = mix->nChannels;
  sound->bits = mix->wBitsPerSample;
  sound->rate = (int)mix->nSamplesPerSec;
  sound->is_float = mix->wFormatTag == 3 /* WAVE_FORMAT_IEEE_FLOAT */;
  // WAVE_FORMAT_EXTENSIBLE: the sample type is the GUID at byte 24 of WAVEFORMATEXTENSIBLE.
  if (mix->wFormatTag == 0xFFFE && mix->cbSize >= 22) {
    GUID subformat;
    memcpy(&subformat, (const uint8_t *)mix + 24, sizeof(subformat));
    sound->is_float = same_guid(&subformat, &kSubtypeFloat);
    if (!sound->is_float && !same_guid(&subformat, &kSubtypePcm)) sound->bits = 0;
  }
  HRESULT initialised = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, loopback, 2000000, 0, mix, NULL);
  CoTaskMemFree(mix);
  if (FAILED(initialised) || sound->channels < 1 || sound->rate < 8000 || sound->bits == 0) {
    IAudioClient_Release(client);
    return NULL;
  }
  *converted = 0;
  *evented = 0;
  return client;
}

static DWORD WINAPI capture(LPVOID argument) {
  Sound *sound = (Sound *)argument;
  CoInitializeEx(NULL, COINIT_MULTITHREADED);
  HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
  IAudioClient *client = NULL;
  IAudioCaptureClient *reader = NULL;
  int converted = 1;
  int evented = 0;
  LONG state = SOUND_FAILED;

  if (sound->pid != 0) {
    client = process_client(sound->pid);
    if (client) {
      WAVEFORMATEX format;
      fill_format(&format);
      // Process loopback takes our format and converts to it; it signals by event.
      if (SUCCEEDED(IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 2000000, 0, &format, NULL)) &&
          SUCCEEDED(IAudioClient_SetEventHandle(client, event))) {
        evented = 1;
        state = SOUND_GAME;
      } else {
        IAudioClient_Release(client);
        client = NULL;
      }
    }
  }
  if (!client && sound->allow_system) {
    client = system_client(sound, event, &converted, &evented);
    if (client) state = SOUND_SYSTEM;
  }
  if (client && (FAILED(IAudioClient_GetService(client, &kIAudioCaptureClient, (void **)&reader)) || FAILED(IAudioClient_Start(client)))) {
    state = SOUND_FAILED;
  }
  InterlockedExchange(&sound->state, client && reader ? state : SOUND_FAILED);

  while (sound->state > 0 && !sound->stop) {
    if (evented) {
      WaitForSingleObject(event, 20);
    } else {
      Sleep(5);
    }
    UINT32 waiting = 0;
    while (!sound->stop && SUCCEEDED(IAudioCaptureClient_GetNextPacketSize(reader, &waiting)) && waiting > 0) {
      BYTE *data = NULL;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(IAudioCaptureClient_GetBuffer(reader, &data, &frames, &flags, NULL, NULL))) break;
      int silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      if (converted) {
        if (silent) {
          uint8_t zeros[1024];
          memset(zeros, 0, sizeof(zeros));
          UINT32 left = frames * 4;
          while (left > 0) {
            UINT32 part = left > sizeof(zeros) ? (UINT32)sizeof(zeros) : left;
            ring_put(sound, zeros, (int)part);
            left -= part;
          }
        } else {
          ring_put(sound, data, (int)(frames * 4));
        }
      } else {
        convert(sound, data, frames, silent);
      }
      IAudioCaptureClient_ReleaseBuffer(reader, frames);
    }
  }

  if (client) IAudioClient_Stop(client);
  if (reader) IAudioCaptureClient_Release(reader);
  if (client) IAudioClient_Release(client);
  CloseHandle(event);
  CoUninitialize();
  return 0;
}

ANYPS5_EXPORT void *anyps5_sound_open(uint32_t pid, int32_t allow_system) {
  Sound *sound = (Sound *)calloc(1, sizeof(Sound));
  if (!sound) return NULL;
  InitializeCriticalSection(&sound->lock);
  sound->pid = pid;
  sound->allow_system = allow_system;
  sound->state = SOUND_STARTING;
  sound->thread = CreateThread(NULL, 0, capture, sound, 0, NULL);
  if (!sound->thread) {
    DeleteCriticalSection(&sound->lock);
    free(sound);
    return NULL;
  }
  return sound;
}

ANYPS5_EXPORT int32_t anyps5_sound_state(void *handle) {
  return handle ? ((Sound *)handle)->state : SOUND_FAILED;
}

ANYPS5_EXPORT int32_t anyps5_sound_read(void *handle, uint8_t *out, int32_t size) {
  if (!handle || !out || size <= 0) return 0;
  Sound *sound = (Sound *)handle;
  EnterCriticalSection(&sound->lock);
  int length = sound->count < size ? sound->count : size;
  // Whole frames only.
  length -= length % 4;
  int start = (sound->head - sound->count + RING_BYTES) % RING_BYTES;
  for (int index = 0; index < length; index++) out[index] = sound->ring[(start + index) % RING_BYTES];
  sound->count -= length;
  LeaveCriticalSection(&sound->lock);
  return length;
}

ANYPS5_EXPORT void anyps5_sound_close(void *handle) {
  if (!handle) return;
  Sound *sound = (Sound *)handle;
  InterlockedExchange(&sound->stop, 1);
  if (WaitForSingleObject(sound->thread, 3000) != WAIT_OBJECT_0) {
    // A device that hangs: the thread keeps the memory rather than read freed memory.
    CloseHandle(sound->thread);
    return;
  }
  CloseHandle(sound->thread);
  DeleteCriticalSection(&sound->lock);
  free(sound);
}

#else

ANYPS5_EXPORT void *anyps5_sound_open(uint32_t pid, int32_t allow_system) {
  (void)pid;
  (void)allow_system;
  return NULL;
}

ANYPS5_EXPORT int32_t anyps5_sound_state(void *handle) {
  (void)handle;
  return SOUND_FAILED;
}

ANYPS5_EXPORT int32_t anyps5_sound_read(void *handle, uint8_t *out, int32_t size) {
  (void)handle;
  (void)out;
  (void)size;
  return 0;
}

ANYPS5_EXPORT void anyps5_sound_close(void *handle) { (void)handle; }

#endif
