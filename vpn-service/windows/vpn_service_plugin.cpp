#include "include/vpn_service/vpn_service_plugin.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace vpn_service {

// static
void VpnServicePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<VpnServicePlugin>();
  registrar->AddPlugin(std::move(plugin));
}

VpnServicePlugin::VpnServicePlugin() {}

VpnServicePlugin::~VpnServicePlugin() {}

}  // namespace vpn_service
