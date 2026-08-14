#include <algorithm>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // Ajustar la ventana al área útil disponible. Esto evita que el contenido
  // quede fuera de pantalla en laptops antiguas con paneles de 1024x600 o
  // 1366x768, manteniendo un tamaño cómodo en monitores modernos.
  RECT work_area{};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  const int available_width = work_area.right - work_area.left;
  const int available_height = work_area.bottom - work_area.top;
  const int window_width =
      std::min(1100, std::max(480, available_width - 48));
  const int window_height =
      std::min(680, std::max(480, available_height - 48));
  const int window_left =
      work_area.left + std::max(0, (available_width - window_width) / 2);
  const int window_top =
      work_area.top + std::max(0, (available_height - window_height) / 2);

  Win32Window::Point origin(window_left, window_top);
  Win32Window::Size size(window_width, window_height);
  if (!window.Create(L"QR Sucursal", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
