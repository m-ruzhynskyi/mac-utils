// mu-audio.exe — помощник Mac Utils Share (Windows 10 2004+).
//   list                 → JSON-список программ, у которых есть звук: [{"name":"Discord.exe"}, …]
//   capture [имя.exe …]  → в stdout PCM 16 бит, моно, 24 кГц: звук всех программ, кроме перечисленных
//                          (как «Не передавать звук программ» на Mac; глушатся и их дочерние процессы).
//   track <hwnd>         → строки «x y w h» (физические пиксели), когда окно двигается; «hidden» — свёрнуто.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <audioclientactivationparams.h>
#include <dwmapi.h>
#include <tlhelp32.h>
#include <wrl/implements.h>
#include <io.h>
#include <fcntl.h>
#include <cstdio>
#include <cwchar>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <algorithm>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "mmdevapi.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "user32.lib")

using Microsoft::WRL::ComPtr;

struct Proc { DWORD parent; std::wstring name; };

static std::map<DWORD, Proc> processes() {
  std::map<DWORD, Proc> result;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return result;
  PROCESSENTRY32W entry = { sizeof(entry) };
  for (BOOL ok = Process32FirstW(snap, &entry); ok; ok = Process32NextW(snap, &entry))
    result[entry.th32ProcessID] = { entry.th32ParentProcessID, entry.szExeFile };
  CloseHandle(snap);
  return result;
}

// Процессы, у которых есть звуковые сессии (на всех устройствах вывода).
static std::set<DWORD> audioPids() {
  std::set<DWORD> pids;
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return pids;
  ComPtr<IMMDeviceCollection> devices;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices))) return pids;
  UINT count = 0;
  devices->GetCount(&count);
  for (UINT d = 0; d < count; d++) {
    ComPtr<IMMDevice> device;
    ComPtr<IAudioSessionManager2> manager;
    ComPtr<IAudioSessionEnumerator> sessions;
    if (FAILED(devices->Item(d, &device)) ||
        FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, (void**)manager.GetAddressOf())) ||
        FAILED(manager->GetSessionEnumerator(&sessions))) continue;
    int total = 0;
    sessions->GetCount(&total);
    for (int i = 0; i < total; i++) {
      ComPtr<IAudioSessionControl> control;
      ComPtr<IAudioSessionControl2> control2;
      DWORD pid = 0;
      if (FAILED(sessions->GetSession(i, &control)) || FAILED(control.As(&control2))) continue;
      if (control2->IsSystemSoundsSession() == S_OK) continue;
      if (SUCCEEDED(control2->GetProcessId(&pid)) && pid) pids.insert(pid);
    }
  }
  return pids;
}

static std::string utf8(const std::wstring& text) {
  int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), (int)text.size(), nullptr, 0, nullptr, nullptr);
  std::string out(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), (int)text.size(), out.data(), size, nullptr, nullptr);
  return out;
}

static int list() {
  auto procs = processes();
  std::set<std::wstring> seen;
  std::string json = "[";
  for (DWORD pid : audioPids()) {
    auto it = procs.find(pid);
    if (it == procs.end()) continue;
    std::wstring lower = it->second.name;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::towlower);
    if (!seen.insert(lower).second) continue;
    std::string name;
    for (char c : utf8(it->second.name)) {
      if (c == '"' || c == '\\') name += '\\';
      name += c;
    }
    if (json.size() > 1) json += ",";
    json += "{\"name\":\"" + name + "\"}";
  }
  json += "]";
  printf("%s\n", json.c_str());
  return 0;
}

// ---- Захват звука одной программы (с дочерними процессами) ----

class Activator : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                                      Microsoft::WRL::FtmBase, IActivateAudioInterfaceCompletionHandler> {
 public:
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HRESULT result = E_FAIL;
  ComPtr<IAudioClient> client;
  ~Activator() { CloseHandle(done); }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT hr = E_FAIL;
    ComPtr<IUnknown> unknown;
    if (SUCCEEDED(operation->GetActivateResult(&hr, &unknown)) && SUCCEEDED(hr)) hr = unknown.As(&client);
    result = hr;
    SetEvent(done);
    return S_OK;
  }
};

const int RATE = 48000;

struct Source {
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  HANDLE event = nullptr;
  std::vector<int> buffer;  // моно, 48 кГц
};

static bool open(DWORD pid, Source& source) {
  AUDIOCLIENT_ACTIVATION_PARAMS params = {};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  params.ProcessLoopbackParams.TargetProcessId = pid;
  PROPVARIANT prop = {};
  prop.vt = VT_BLOB;
  prop.blob.cbSize = sizeof(params);
  prop.blob.pBlobData = (BYTE*)&params;
  auto activator = Microsoft::WRL::Make<Activator>();
  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  if (FAILED(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &prop,
                                         activator.Get(), &operation))) return false;
  if (WaitForSingleObject(activator->done, 3000) != WAIT_OBJECT_0 || FAILED(activator->result)) return false;
  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = 2;
  format.nSamplesPerSec = RATE;
  format.wBitsPerSample = 16;
  format.nBlockAlign = 4;
  format.nAvgBytesPerSec = RATE * 4;
  source.client = activator->client;
  if (FAILED(source.client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                       2000000, 0, &format, nullptr))) return false;
  source.event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (FAILED(source.client->SetEventHandle(source.event)) ||
      FAILED(source.client->GetService(IID_PPV_ARGS(&source.capture))) ||
      FAILED(source.client->Start())) return false;
  return true;
}

static void close(Source& source) {
  if (source.client) source.client->Stop();
  if (source.event) CloseHandle(source.event);
  source = Source();
}

// Забрать всё, что накопилось; false — программа закрылась.
static bool drain(Source& source) {
  UINT32 packet = 0;
  while (true) {
    if (FAILED(source.capture->GetNextPacketSize(&packet))) return false;
    if (!packet) return true;
    BYTE* data = nullptr;
    UINT32 frames = 0;
    DWORD flags = 0;
    if (FAILED(source.capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) return false;
    const short* samples = (const short*)data;
    for (UINT32 i = 0; i < frames; i++)
      source.buffer.push_back((flags & AUDCLNT_BUFFERFLAGS_SILENT) ? 0 : (samples[i * 2] + samples[i * 2 + 1]) / 2);
    source.capture->ReleaseBuffer(frames);
    // Не копим больше 0,3 с — иначе звук отстанет от картинки.
    if (source.buffer.size() > RATE * 3 / 10) source.buffer.erase(source.buffer.begin(), source.buffer.end() - RATE / 10);
  }
}

static int capture(const std::vector<std::wstring>& muted) {
  _setmode(_fileno(stdout), _O_BINARY);
  auto isMuted = [&](const std::wstring& name) {
    for (auto& m : muted) if (_wcsicmp(m.c_str(), name.c_str()) == 0) return true;
    return false;
  };
  const std::wstring self = L"Mac Utils Share.exe";
  std::map<DWORD, Source> sources;
  LARGE_INTEGER frequency, start, now;
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&start);
  long long produced = 0;           // кадров 48 кГц выдано
  ULONGLONG lastScan = 0;
  std::vector<short> out;
  const int CHUNK = RATE / 50;      // 20 мс
  while (true) {
    ULONGLONG tick = GetTickCount64();
    if (tick - lastScan > 2000) {
      lastScan = tick;
      auto procs = processes();
      std::set<DWORD> candidates;
      for (DWORD pid : audioPids()) {
        auto it = procs.find(pid);
        if (it != procs.end() && !isMuted(it->second.name) && _wcsicmp(it->second.name.c_str(), self.c_str()) != 0)
          candidates.insert(pid);
      }
      // Дочерние процессы уже входят в «дерево» родителя — второй раз не берём, иначе звук удвоится.
      std::set<DWORD> roots;
      for (DWORD pid : candidates) {
        bool covered = false;
        std::set<DWORD> visited{pid};
        for (auto it = procs.find(pid); it != procs.end() && visited.insert(it->second.parent).second;
             it = procs.find(it->second.parent)) {
          if (candidates.count(it->second.parent)) { covered = true; break; }
        }
        if (!covered) roots.insert(pid);
      }
      for (auto it = sources.begin(); it != sources.end();) {
        if (!roots.count(it->first)) { close(it->second); it = sources.erase(it); } else ++it;
      }
      for (DWORD pid : roots) {
        if (sources.count(pid)) continue;
        Source source;
        if (open(pid, source)) sources[pid] = std::move(source); else close(source);
      }
    }
    for (auto it = sources.begin(); it != sources.end();) {
      if (!drain(it->second)) { close(it->second); it = sources.erase(it); } else ++it;
    }
    QueryPerformanceCounter(&now);
    long long due = (now.QuadPart - start.QuadPart) * RATE / frequency.QuadPart;
    if (due - produced > RATE / 2) produced = due - CHUNK;  // отстали (сон, зависание) — не догоняем
    while (due - produced >= CHUNK) {
      for (int i = 0; i < CHUNK; i += 2) {
        int mix[2] = {0, 0};
        for (auto& [pid, source] : sources) {
          for (int k = 0; k < 2; k++) mix[k] += i + k < (int)source.buffer.size() ? source.buffer[i + k] : 0;
        }
        int value = (mix[0] + mix[1]) / 2;  // 48 → 24 кГц
        out.push_back((short)std::clamp(value, -32768, 32767));
      }
      for (auto& [pid, source] : sources)
        source.buffer.erase(source.buffer.begin(), source.buffer.begin() + std::min<size_t>(CHUNK, source.buffer.size()));
      produced += CHUNK;
    }
    if (out.size() >= 2400) {  // по 0,1 с
      if (fwrite(out.data(), 2, out.size(), stdout) != out.size() || fflush(stdout) != 0) return 0;
      out.clear();
    }
    Sleep(10);
  }
}

// ---- Где окно (для меток зрителей поверх транслируемого окна) ----

static int track(HWND window) {
  RECT last = {};
  bool hidden = false;
  while (IsWindow(window)) {
    if (IsIconic(window) || !IsWindowVisible(window)) {
      if (!hidden) { printf("hidden\n"); fflush(stdout); hidden = true; }
    } else {
      RECT rect = {};
      if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &rect, sizeof(rect)))) GetWindowRect(window, &rect);
      if (hidden || memcmp(&rect, &last, sizeof(rect)) != 0) {
        last = rect;
        hidden = false;
        if (printf("%ld %ld %ld %ld\n", rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top) < 0 || fflush(stdout) != 0) return 0;
      }
    }
    Sleep(200);
  }
  printf("gone\n");
  return 0;
}

int wmain(int argc, wchar_t** argv) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (argc < 2) return 2;
  std::wstring command = argv[1];
  if (command == L"track" && argc > 2) return track((HWND)(INT_PTR)_wcstoi64(argv[2], nullptr, 10));
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 1;
  if (command == L"list") return list();
  if (command == L"capture") return capture(std::vector<std::wstring>(argv + 2, argv + argc));
  return 2;
}
