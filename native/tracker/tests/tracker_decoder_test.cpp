#include "tracker_decoder.h"

#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {
void PutText(std::vector<unsigned char>* bytes,
             std::size_t offset,
             const std::string& value) {
  for (std::size_t index = 0; index < value.size(); ++index) {
    (*bytes)[offset + index] = static_cast<unsigned char>(value[index]);
  }
}

bool Check(bool condition, const std::string& message) {
  if (condition) return true;
  std::cerr << message << '\n';
  return false;
}
}  // namespace

int main() {
  const auto directory = std::filesystem::temp_directory_path();
  const auto module_path = directory / "neonamp-tracker-test.mod";
  const auto wave_path = directory / "neonamp-tracker-test.wav";
  std::vector<unsigned char> module(1084 + 1024 + 2);
  PutText(&module, 0, "NeonAmp decoder test");
  module[42] = 0;
  module[43] = 1;  // One 16-bit sample word.
  module[45] = 64;
  module[950] = 1;  // One pattern in the order list.
  module[951] = 0x7f;  // Do not restart the pattern after its first pass.
  PutText(&module, 1080, "M.K.");
  module[1084] = 0x01;
  module[1085] = 0xac;
  module[1086] = 0x1c;
  module[1087] = 0xc0;
  module[2108] = 0x7f;
  module[2109] = 0x80;
  {
    std::ofstream file(module_path, std::ios::binary | std::ios::trunc);
    file.write(reinterpret_cast<const char*>(module.data()), module.size());
  }

  TrackerModuleInfo info;
  std::string error;
  if (!Check(ReadTrackerModuleInfo(module_path.u8string(), &info, &error),
             "Module metadata failed: " + error) ||
      !Check(info.title == "NeonAmp decoder test", "Module title mismatch") ||
      !Check(!info.format.empty(),
             "Module format was not identified")) {
    return 1;
  }
  const bool rendered = RenderTrackerModuleToWav(
      module_path.u8string(), wave_path.u8string(), &error);
  if (!Check(rendered, "Module rendering failed: " + error)) {
    return 1;
  }

  std::ifstream wave(wave_path, std::ios::binary | std::ios::ate);
  const auto size = wave.tellg();
  if (!Check(size > 44, "Rendered WAV is empty")) return 1;
  std::array<char, 12> header{};
  wave.seekg(0);
  wave.read(header.data(), header.size());
  const bool valid_header = std::string(header.data(), 4) == "RIFF" &&
                            std::string(header.data() + 8, 4) == "WAVE";
  std::error_code ignored;
  std::filesystem::remove(module_path, ignored);
  std::filesystem::remove(wave_path, ignored);
  return Check(valid_header, "Rendered file is not a RIFF/WAVE audio file") ? 0
                                                                            : 1;
}
