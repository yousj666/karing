#ifndef FLUTTER_PLUGIN_VPN_SERVICE_PLUGIN_H_
#define FLUTTER_PLUGIN_VPN_SERVICE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace vpn_service {

// STUB (yousj-plus reconstruction): platform bridge lands in phase R4.
class VpnServicePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  VpnServicePlugin();

  virtual ~VpnServicePlugin();

  VpnServicePlugin(const VpnServicePlugin &) = delete;
  VpnServicePlugin &operator=(const VpnServicePlugin &) = delete;
};

}  // namespace vpn_service

#endif  // FLUTTER_PLUGIN_VPN_SERVICE_PLUGIN_H_
