LibAtrac9 (https://github.com/Thealexbarney/LibAtrac9, MIT, see LICENSE), the C decoder as the
macOS launcher carries it (tools/macos/launcher/Sources/CAtrac9 in AnyPS5): the engine's three
bounds and speed fixes from core/libs/prx/libSceAjm.native/PatchLibAtrac9.cmake are already
applied to unpack.c, decinit.c and bit_reader.c. The launcher uses it to play a game's theme song
(sce_sys/snd0.at9).

anyps5_atrac9.c is this launcher's own: the few functions Dart calls, exported from the shared
library that hook/build.dart builds (MSVC on Windows, the system compiler on Linux).
