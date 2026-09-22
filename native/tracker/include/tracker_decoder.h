#pragma once

#include <string>

struct TrackerModuleInfo {
  std::string title;
  std::string format;
};

bool ReadTrackerModuleInfo(const std::string& input_path,
                           TrackerModuleInfo* info,
                           std::string* error);

bool RenderTrackerModuleToWav(const std::string& input_path,
                              const std::string& output_path,
                              std::string* error);
