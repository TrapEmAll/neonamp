#include "flutter_window.h"

#include <optional>
#include <string>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/base.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

bool TranscodeToM4a(const std::wstring& input_path,
                    const std::wstring& output_path) {
  if (FAILED(MFStartup(MF_VERSION))) return false;
  bool success = false;
  winrt::com_ptr<IMFSourceReader> reader;
  winrt::com_ptr<IMFSinkWriter> writer;
  try {
    winrt::check_hresult(MFCreateSourceReaderFromURL(
        input_path.c_str(), nullptr, reader.put()));
    constexpr DWORD audio_stream =
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    winrt::check_hresult(reader->SetStreamSelection(
        static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE));
    winrt::check_hresult(reader->SetStreamSelection(audio_stream, TRUE));

    winrt::com_ptr<IMFMediaType> native_type;
    winrt::check_hresult(reader->GetNativeMediaType(audio_stream, 0,
                                                    native_type.put()));
    UINT32 sample_rate = 44100;
    UINT32 channels = 2;
    native_type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sample_rate);
    native_type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);

    winrt::com_ptr<IMFMediaType> pcm_type;
    winrt::check_hresult(MFCreateMediaType(pcm_type.put()));
    winrt::check_hresult(pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
    winrt::check_hresult(pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM));
    winrt::check_hresult(
        pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate));
    winrt::check_hresult(
        pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels));
    winrt::check_hresult(pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16));
    winrt::check_hresult(pcm_type->SetUINT32(
        MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * sizeof(INT16)));
    winrt::check_hresult(pcm_type->SetUINT32(
        MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
        sample_rate * channels * sizeof(INT16)));
    winrt::check_hresult(
        reader->SetCurrentMediaType(audio_stream, nullptr, pcm_type.get()));

    winrt::check_hresult(MFCreateSinkWriterFromURL(
        output_path.c_str(), nullptr, nullptr, writer.put()));
    winrt::com_ptr<IMFMediaType> aac_type;
    winrt::check_hresult(MFCreateMediaType(aac_type.put()));
    winrt::check_hresult(aac_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
    winrt::check_hresult(aac_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC));
    winrt::check_hresult(
        aac_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate));
    winrt::check_hresult(
        aac_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels));
    winrt::check_hresult(aac_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                             192000 / 8));

    DWORD output_stream = 0;
    winrt::check_hresult(writer->AddStream(aac_type.get(), &output_stream));
    winrt::check_hresult(
        writer->SetInputMediaType(output_stream, pcm_type.get(), nullptr));
    winrt::check_hresult(writer->BeginWriting());

    while (true) {
      DWORD flags = 0;
      LONGLONG timestamp = 0;
      winrt::com_ptr<IMFSample> sample;
      winrt::check_hresult(reader->ReadSample(audio_stream, 0, nullptr, &flags,
                                              &timestamp, sample.put()));
      if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) break;
      if (sample) {
        winrt::check_hresult(sample->SetSampleTime(timestamp));
        winrt::check_hresult(writer->WriteSample(output_stream, sample.get()));
      }
    }
    winrt::check_hresult(writer->Finalize());
    success = true;
  } catch (...) {
    if (writer) writer->Finalize();
  }
  if (!success) DeleteFileW(output_path.c_str());
  MFShutdown();
  return success;
}

std::wstring GetStringArgument(const flutter::EncodableMap& values,
                               const char* key) {
  const auto found = values.find(flutter::EncodableValue(key));
  if (found == values.end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  if (value == nullptr) return {};
  return std::wstring(value->begin(), value->end());
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  system_controls_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "neonamp/system_controls",
      &flutter::StandardMethodCodec::GetInstance());
  system_controls_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "setMediaSession") {
          const auto* values = std::get_if<flutter::EncodableMap>(call.arguments());
          if (values != nullptr) {
            UpdateSystemMediaControls(*values);
          }
          result->Success();
        } else if (call.method_name() == "convertToM4a") {
          const auto* values = std::get_if<flutter::EncodableMap>(call.arguments());
          if (values == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const auto input_path = GetStringArgument(*values, "inputPath");
          const auto output_path = GetStringArgument(*values, "outputPath");
          result->Success(flutter::EncodableValue(
              !input_path.empty() && !output_path.empty() &&
              TranscodeToM4a(input_path, output_path)));
        } else {
          result->NotImplemented();
        }
      });
  InitializeSystemMediaControls();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (system_media_controls_ != nullptr && system_media_button_token_.value != 0) {
    system_media_controls_.ButtonPressed(system_media_button_token_);
    system_media_button_token_ = {};
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::InitializeSystemMediaControls() {
  try {
    auto activation_factory = winrt::get_activation_factory<
        winrt::Windows::Media::SystemMediaTransportControls>();
    auto interop_factory =
        activation_factory.as<ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop_factory->GetForWindow(
        GetHandle(),
        winrt::guid_of<winrt::Windows::Media::SystemMediaTransportControls>(),
        winrt::put_abi(system_media_controls_)));
    system_media_controls_.IsEnabled(true);
    system_media_controls_.IsPlayEnabled(true);
    system_media_controls_.IsPauseEnabled(true);
    system_media_controls_.IsStopEnabled(true);
    system_media_controls_.IsNextEnabled(true);
    system_media_controls_.IsPreviousEnabled(true);
    system_media_controls_.DisplayUpdater().Type(
        winrt::Windows::Media::MediaPlaybackType::Music);
    system_media_button_token_ = system_media_controls_.ButtonPressed(
        [this](const auto&, const auto& args) {
          const auto button = args.Button();
          const char* media_key = nullptr;
          using Button = winrt::Windows::Media::SystemMediaTransportControlsButton;
          switch (button) {
            case Button::Play:
              media_key = "play";
              break;
            case Button::Pause:
              media_key = "pause";
              break;
            case Button::Stop:
              media_key = "stop";
              break;
            case Button::Next:
              media_key = "next";
              break;
            case Button::Previous:
              media_key = "previous";
              break;
            default:
              break;
          }
          if (media_key != nullptr && system_controls_channel_) {
            system_controls_channel_->InvokeMethod(
                "mediaKey",
                std::make_unique<flutter::EncodableValue>(
                    std::string(media_key)));
          }
        });
  } catch (...) {
    system_media_controls_ = nullptr;
  }
}

void FlutterWindow::UpdateSystemMediaControls(
    const flutter::EncodableMap& values) {
  if (system_media_controls_ == nullptr) return;
  auto get_string = [&values](const char* key) {
    const auto found = values.find(flutter::EncodableValue(key));
    if (found == values.end()) return std::string();
    const auto* value = std::get_if<std::string>(&found->second);
    return value == nullptr ? std::string() : *value;
  };
  auto get_bool = [&values](const char* key) {
    const auto found = values.find(flutter::EncodableValue(key));
    if (found == values.end()) return false;
    const auto* value = std::get_if<bool>(&found->second);
    return value != nullptr && *value;
  };
  try {
    auto updater = system_media_controls_.DisplayUpdater();
    auto properties = updater.MusicProperties();
    properties.Title(winrt::to_hstring(get_string("title")));
    properties.Artist(winrt::to_hstring(get_string("artist")));
    properties.AlbumTitle(winrt::to_hstring(get_string("album")));
    updater.Update();
    system_media_controls_.PlaybackStatus(
        get_bool("isPlaying")
            ? winrt::Windows::Media::MediaPlaybackStatus::Playing
            : winrt::Windows::Media::MediaPlaybackStatus::Paused);
  } catch (...) {
    // System media controls are optional on older Windows configurations.
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_APPCOMMAND: {
      const auto command = GET_APPCOMMAND_LPARAM(lparam);
      const char* mediaKey = nullptr;
      switch (command) {
        case APPCOMMAND_MEDIA_PLAY_PAUSE:
          mediaKey = "playPause";
          break;
        case APPCOMMAND_MEDIA_NEXTTRACK:
          mediaKey = "next";
          break;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK:
          mediaKey = "previous";
          break;
        case APPCOMMAND_MEDIA_STOP:
          mediaKey = "stop";
          break;
      }
      if (mediaKey != nullptr && system_controls_channel_) {
        system_controls_channel_->InvokeMethod(
            "mediaKey",
            std::make_unique<flutter::EncodableValue>(std::string(mediaKey)));
        return 0;
      }
      break;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
