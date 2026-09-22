#include "tracker_decoder.h"

#include <xmp.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <vector>

namespace {
constexpr int kSampleRate = 44100;
constexpr std::uint64_t kMaximumAudioBytes =
    static_cast<std::uint64_t>(kSampleRate) * 2 * 2 * 60 * 60 * 3;
constexpr std::uint32_t kWaveHeaderSize = 44;

struct ContextDeleter {
  void operator()(char* context) const {
    if (context != nullptr) xmp_free_context(context);
  }
};
using Context = std::unique_ptr<char, ContextDeleter>;

std::string TrimModuleText(const char* text, std::size_t capacity) {
  if (text == nullptr) return {};
  std::size_t length = 0;
  while (length < capacity && text[length] != '\0') ++length;
  while (length > 0 && (text[length - 1] == ' ' || text[length - 1] == '\t')) {
    --length;
  }
  return std::string(text, length);
}

bool LoadModule(const std::string& input_path,
                Context* context,
                std::string* error) {
  try {
    std::ifstream input(std::filesystem::u8path(input_path),
                        std::ios::binary | std::ios::ate);
    if (!input) {
      *error = "Could not open tracker module.";
      return false;
    }
    const auto end = input.tellg();
    if (end <= 0 || static_cast<std::uint64_t>(end) >
                         static_cast<std::uint64_t>(std::numeric_limits<long>::max())) {
      *error = "Tracker module is empty or too large.";
      return false;
    }
    std::vector<char> bytes(static_cast<std::size_t>(end));
    input.seekg(0);
    if (!input.read(bytes.data(), static_cast<std::streamsize>(bytes.size()))) {
      *error = "Could not read tracker module.";
      return false;
    }

    context->reset(xmp_create_context());
    if (!*context) {
      *error = "Could not initialize the tracker decoder.";
      return false;
    }
    const int result = xmp_load_module_from_memory(
        context->get(), bytes.data(), static_cast<long>(bytes.size()));
    if (result != 0) {
      *error = "Unsupported or malformed tracker module.";
      return false;
    }
    return true;
  } catch (const std::filesystem::filesystem_error&) {
    *error = "Could not access tracker module path.";
    return false;
  } catch (const std::bad_alloc&) {
    *error = "Tracker module is too large to decode.";
    return false;
  }
}

void PutU16(std::array<unsigned char, kWaveHeaderSize>* header,
            std::size_t offset,
            std::uint16_t value) {
  (*header)[offset] = static_cast<unsigned char>(value & 0xff);
  (*header)[offset + 1] = static_cast<unsigned char>((value >> 8) & 0xff);
}

void PutU32(std::array<unsigned char, kWaveHeaderSize>* header,
            std::size_t offset,
            std::uint32_t value) {
  for (int byte = 0; byte < 4; ++byte) {
    (*header)[offset + byte] =
        static_cast<unsigned char>((value >> (byte * 8)) & 0xff);
  }
}

std::array<unsigned char, kWaveHeaderSize> MakeWaveHeader(
    std::uint32_t data_size) {
  std::array<unsigned char, kWaveHeaderSize> header{};
  const auto text = [&header](std::size_t offset, const char* value) {
    for (std::size_t i = 0; value[i] != '\0'; ++i) {
      header[offset + i] = static_cast<unsigned char>(value[i]);
    }
  };
  text(0, "RIFF");
  PutU32(&header, 4, data_size + 36);
  text(8, "WAVE");
  text(12, "fmt ");
  PutU32(&header, 16, 16);
  PutU16(&header, 20, 1);
  PutU16(&header, 22, 2);
  PutU32(&header, 24, kSampleRate);
  PutU32(&header, 28, kSampleRate * 4);
  PutU16(&header, 32, 4);
  PutU16(&header, 34, 16);
  text(36, "data");
  PutU32(&header, 40, data_size);
  return header;
}
}  // namespace

bool ReadTrackerModuleInfo(const std::string& input_path,
                           TrackerModuleInfo* info,
                           std::string* error) {
  if (info == nullptr || error == nullptr) return false;
  Context context;
  if (!LoadModule(input_path, &context, error)) return false;
  xmp_module_info module_info{};
  xmp_get_module_info(context.get(), &module_info);
  if (module_info.mod == nullptr) {
    *error = "The file did not contain a playable tracker module.";
    return false;
  }
  info->title = TrimModuleText(module_info.mod->name, XMP_NAME_SIZE);
  info->format = TrimModuleText(module_info.mod->type, XMP_NAME_SIZE);
  return true;
}

bool RenderTrackerModuleToWav(const std::string& input_path,
                              const std::string& output_path,
                              std::string* error) {
  if (error == nullptr) return false;
  Context context;
  if (!LoadModule(input_path, &context, error)) return false;
  if (xmp_start_player(context.get(), kSampleRate, 0) != 0) {
    *error = "Could not start tracker module playback.";
    return false;
  }

  std::ofstream output(std::filesystem::u8path(output_path),
                       std::ios::binary | std::ios::trunc);
  if (!output) {
    xmp_end_player(context.get());
    *error = "Could not create decoded tracker audio.";
    return false;
  }
  const auto placeholder = MakeWaveHeader(0);
  output.write(reinterpret_cast<const char*>(placeholder.data()),
               placeholder.size());

  std::uint64_t audio_bytes = 0;
  xmp_frame_info frame{};
  int result = 0;
  while ((result = xmp_play_frame(context.get())) == 0) {
    xmp_get_frame_info(context.get(), &frame);
    if (frame.buffer_size < 0 ||
        static_cast<std::uint64_t>(frame.buffer_size) >
            kMaximumAudioBytes - audio_bytes) {
      *error = "Invalid tracker frame size: " +
               std::to_string(frame.buffer_size) + ".";
      result = -XMP_ERROR_INVALID;
      break;
    }
    if (frame.buffer_size > 0) {
      output.write(static_cast<const char*>(frame.buffer), frame.buffer_size);
      if (!output) {
        result = -XMP_ERROR_SYSTEM;
        break;
      }
      audio_bytes += static_cast<std::uint64_t>(frame.buffer_size);
    }
    if (frame.loop_count > 0) {
      result = -XMP_END;
      break;
    }
  }
  xmp_end_player(context.get());

  const bool valid_end = result == -XMP_END && audio_bytes > 0 &&
                         (audio_bytes % 4) == 0;
  if (!valid_end || audio_bytes > std::numeric_limits<std::uint32_t>::max()) {
    output.close();
    std::error_code ignored;
    std::filesystem::remove(std::filesystem::u8path(output_path), ignored);
    if (error->empty()) {
      *error = result == -XMP_END
                   ? "Tracker module produced no playable audio."
                   : "Tracker module could not be rendered completely (decoder " +
                         std::to_string(result) + ").";
    }
    return false;
  }

  const auto header = MakeWaveHeader(static_cast<std::uint32_t>(audio_bytes));
  output.seekp(0);
  output.write(reinterpret_cast<const char*>(header.data()), header.size());
  output.close();
  if (!output) {
    std::error_code ignored;
    std::filesystem::remove(std::filesystem::u8path(output_path), ignored);
    *error = "Could not finalize decoded tracker audio.";
    return false;
  }
  return true;
}
