// MCPassthrough for Cyberpunk 2077: a RED4ext plugin that is also a ReShade add-on.
//
// The CET Lua script (mods/mcpassthrough/init.lua) reads Cyberpunk's camera every tick and calls these global
// natives (CET resolves them by short name as Game.MCPT_*):
//   MCPT_Send(String) -> Bool     a JSON message to the Minecraft mod (ws://127.0.0.1:25599)
//   MCPT_Poll() -> String         the next message from Minecraft, or ""
//   MCPT_Pose(String) -> Bool     "active yaw pitch roll vfov x y z near far lag steve sx sy sz" (Minecraft convention)
//                                 for the compositor; lag = how many ticks old the presented picture's camera is (0..6);
//                                 steve = 1 with his centre (third person: his pixels aren't re-projected)
//   MCPT_Status() -> String       "connected generation backbufferWidth backbufferHeight"
//   MCPT_Input(String) -> String  "1": capture clicks + wheel for Minecraft this tick (Cyberpunk doesn't see them);
//                                 returns "focused lmb rmb wheelNotches numberKeyBits mouseDx mouseDy" (only while
//                                 Cyberpunk has focus; mouse counts since the last call)
#include <RED4ext/RED4ext.hpp>
#include <RED4ext/Scripting/Functions.hpp>
#include <RED4ext/Scripting/Utils.hpp>

#include <winsock2.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

#include "compositor.h"
#include "ws.h"

typedef unsigned __int64 QWORD; // NEXTRAWINPUTBLOCK uses it; the Windows headers here don't define it

namespace
{
	constexpr int kPort = 25599;
	WsClient g_ws;
	HMODULE g_module = nullptr;
	bool g_wsStarted = false;

	void ensure_started()
	{
		if (!g_wsStarted)
		{
			g_wsStarted = true;
			g_ws.start("127.0.0.1", kPort);
		}
		compositor::try_register(g_module);
	}

	std::string read_string(RED4ext::CStackFrame *frame)
	{
		RED4ext::CString in;
		RED4ext::GetParameter(frame, &in);
		frame->code++; // ParamEnd
		return in.c_str();
	}

	void MCPT_Send(RED4ext::IScriptable *, RED4ext::CStackFrame *frame, bool *out, int64_t)
	{
		const std::string msg = read_string(frame);
		ensure_started();
		const bool ok = g_ws.connected() && g_ws.send(msg);
		if (out)
			*out = ok;
	}

	void MCPT_Poll(RED4ext::IScriptable *, RED4ext::CStackFrame *frame, RED4ext::CString *out, int64_t)
	{
		frame->code++; // ParamEnd
		ensure_started();
		std::string msg;
		if (!g_ws.poll(msg))
			msg.clear();
		if (out)
			*out = RED4ext::CString(msg.c_str());
	}

	void MCPT_Pose(RED4ext::IScriptable *, RED4ext::CStackFrame *frame, bool *out, int64_t)
	{
		const std::string spec = read_string(frame);
		ensure_started();
		int active = 0, lag = 0, steve = 0;
		float yaw = 0, pitch = 0, roll = 0, fov = 60, nearClip = 0.02f, farClip = 100000.0f;
		double x = 0, y = 0, z = 0, sx = 0, sy = 0, sz = 0;
		const int n = std::sscanf(spec.c_str(), "%d %f %f %f %f %lf %lf %lf %f %f %d %d %lf %lf %lf", &active, &yaw, &pitch, &roll, &fov, &x,
			&y, &z, &nearClip, &farClip, &lag, &steve, &sx, &sy, &sz);
		if (n >= 15)
			compositor::set_steve(steve != 0, sx, sy, sz);
		else if (n >= 8)
			compositor::set_steve(false, 0, 0, 0);
		const bool ok = n >= 8;
		if (ok)
		{
			compositor::set_active(active != 0);
			// only real poses go into the history (an inactive call carries zeros)
			if (active != 0)
				compositor::set_host_pose(yaw, pitch, roll, fov, x, y, z);
			if (n >= 10)
				compositor::set_host_planes(nearClip, farClip);
			if (n >= 11)
				compositor::set_pose_lag(lag);
		}
		if (out)
			*out = ok;
	}

	void MCPT_Status(RED4ext::IScriptable *, RED4ext::CStackFrame *frame, RED4ext::CString *out, int64_t)
	{
		frame->code++; // ParamEnd
		ensure_started();
		int bw = 0, bh = 0;
		compositor::backbuffer_size(bw, bh);
		char buf[96];
		std::snprintf(buf, sizeof(buf), "%d %d %d %d", g_ws.connected() ? 1 : 0, g_ws.generation(), bw, bh);
		if (out)
			*out = RED4ext::CString(buf);
	}

	// Input for Minecraft: mouse buttons and number keys from GetAsyncKeyState, the wheel from a low-level mouse hook on
	// its own thread (it only counts wheel notches and passes everything on at once). Reported only while a window of
	// this process (Cyberpunk) has the focus, so typing elsewhere never reaches Minecraft.
	std::atomic<int> g_wheel{0};
	std::thread g_hookThread;
	DWORD g_hookThreadId = 0;
	// Capture: while the script says the player is in gameplay (no menu, no overlay), the buttons and the wheel are
	// Minecraft's alone: the hook records them and swallows them, so Cyberpunk doesn't also zoom, aim or switch weapons.
	std::atomic<bool> g_capture{false};
	std::atomic<bool> g_lmb{false}, g_rmb{false};
	std::atomic<ULONGLONG> g_captureUntil{0};

	bool game_focused();

	LRESULT CALLBACK mouse_hook(int code, WPARAM wp, LPARAM lp)
	{
		if (code == HC_ACTION)
		{
			// capture lapses by itself unless the script renews it every tick (a crashed or stopped script frees the mouse)
			const bool capture = g_capture && GetTickCount64() < g_captureUntil && game_focused();
			switch (wp)
			{
			case WM_MOUSEWHEEL:
				if (game_focused())
					g_wheel += GET_WHEEL_DELTA_WPARAM(reinterpret_cast<const MSLLHOOKSTRUCT *>(lp)->mouseData);
				if (capture)
					return 1;
				break;
			case WM_LBUTTONDOWN:
			case WM_LBUTTONUP:
				g_lmb = wp == WM_LBUTTONDOWN && game_focused();
				if (capture || (wp == WM_LBUTTONUP && g_capture))
					return 1;
				break;
			case WM_RBUTTONDOWN:
			case WM_RBUTTONUP:
				g_rmb = wp == WM_RBUTTONDOWN && game_focused();
				if (capture || (wp == WM_RBUTTONUP && g_capture))
					return 1;
				break;
			}
		}
		return CallNextHookEx(nullptr, code, wp, lp);
	}

	void start_input()
	{
		if (g_hookThread.joinable())
			return;
		g_hookThread = std::thread([] {
			g_hookThreadId = GetCurrentThreadId();
			HHOOK hook = SetWindowsHookExW(WH_MOUSE_LL, mouse_hook, g_module, 0);
			MSG msg;
			while (GetMessageW(&msg, nullptr, 0, 0) > 0)
			{
				TranslateMessage(&msg);
				DispatchMessageW(&msg);
			}
			if (hook)
				UnhookWindowsHookEx(hook);
		});
	}

	void stop_input()
	{
		if (!g_hookThread.joinable())
			return;
		PostThreadMessageW(g_hookThreadId, WM_QUIT, 0, 0);
		g_hookThread.join();
	}

	// Cyberpunk reads the mouse with Raw Input, which the low-level hook can't block: while capturing, the click and
	// wheel bits are cleared from what GetRawInputData / GetRawInputBuffer hand back (movement passes through).
	using GetRawInputData_t = UINT(WINAPI *)(HRAWINPUT, UINT, LPVOID, PUINT, UINT);
	using GetRawInputBuffer_t = UINT(WINAPI *)(PRAWINPUT, PUINT, UINT);
	GetRawInputData_t g_origGetRawInputData = nullptr;
	GetRawInputBuffer_t g_origGetRawInputBuffer = nullptr;
	constexpr USHORT kCapturedButtons = RI_MOUSE_LEFT_BUTTON_DOWN | RI_MOUSE_LEFT_BUTTON_UP | RI_MOUSE_RIGHT_BUTTON_DOWN |
		RI_MOUSE_RIGHT_BUTTON_UP | RI_MOUSE_WHEEL | RI_MOUSE_HWHEEL;

	bool capturing()
	{
		return g_capture && GetTickCount64() < g_captureUntil;
	}

	// raw mouse movement Cyberpunk reads (relative counts), for steering where Cyberpunk's own camera can't turn
	std::atomic<long> g_mouseDx{0}, g_mouseDy{0};

	void count_mouse(const RAWINPUT *ri)
	{
		if (ri->header.dwType == RIM_TYPEMOUSE && !(ri->data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE))
		{
			g_mouseDx += ri->data.mouse.lLastX;
			g_mouseDy += ri->data.mouse.lLastY;
		}
	}

	void strip_mouse(RAWINPUT *ri)
	{
		if (ri->header.dwType != RIM_TYPEMOUSE)
			return;
		USHORT &flags = ri->data.mouse.usButtonFlags;
		if (flags & (RI_MOUSE_WHEEL | RI_MOUSE_HWHEEL))
			ri->data.mouse.usButtonData = 0;
		flags &= ~kCapturedButtons;
	}

	UINT WINAPI hook_GetRawInputData(HRAWINPUT input, UINT command, LPVOID data, PUINT size, UINT headerSize)
	{
		const UINT result = g_origGetRawInputData(input, command, data, size, headerSize);
		if (command == RID_INPUT && data != nullptr && result != UINT(-1) && result >= sizeof(RAWINPUTHEADER))
		{
			count_mouse(static_cast<RAWINPUT *>(data));
			if (capturing())
				strip_mouse(static_cast<RAWINPUT *>(data));
		}
		return result;
	}

	UINT WINAPI hook_GetRawInputBuffer(PRAWINPUT data, PUINT size, UINT headerSize)
	{
		const UINT count = g_origGetRawInputBuffer(data, size, headerSize);
		if (data != nullptr && count != UINT(-1) && count > 0)
		{
			const bool capture = capturing();
			PRAWINPUT ri = data;
			for (UINT i = 0; i < count; ++i)
			{
				count_mouse(ri);
				if (capture)
					strip_mouse(ri);
				ri = NEXTRAWINPUTBLOCK(ri);
			}
		}
		return count;
	}

	bool game_focused()
	{
		HWND fg = GetForegroundWindow();
		DWORD pid = 0;
		GetWindowThreadProcessId(fg, &pid);
		return fg != nullptr && pid == GetCurrentProcessId();
	}

	// MCPT_Input("1"|"0": capture the mouse for Minecraft this tick) -> "focused lmb rmb wheelNotches keys"
	// (keys: bit i = number key i+1 held). Buttons come from the hook (swallowed clicks never reach GetAsyncKeyState).
	void MCPT_Input(RED4ext::IScriptable *, RED4ext::CStackFrame *frame, RED4ext::CString *out, int64_t)
	{
		const std::string arg = read_string(frame);
		start_input();
		const bool capture = arg == "1";
		g_capture = capture;
		if (capture)
			g_captureUntil = GetTickCount64() + 500;
		const int wheel = g_wheel.exchange(0);
		const bool focused = game_focused();
		int keys = 0;
		bool lmb = false, rmb = false;
		if (focused)
		{
			lmb = g_lmb;
			rmb = g_rmb;
			for (int i = 0; i < 9; ++i)
				if (GetAsyncKeyState('1' + i) & 0x8000)
					keys |= 1 << i;
		}
		const long dx = g_mouseDx.exchange(0), dy = g_mouseDy.exchange(0);
		char buf[96];
		std::snprintf(buf, sizeof(buf), "%d %d %d %d %d %ld %ld", focused ? 1 : 0, lmb ? 1 : 0, rmb ? 1 : 0, focused ? wheel / WHEEL_DELTA : 0,
			keys, focused ? dx : 0L, focused ? dy : 0L);
		if (out)
			*out = RED4ext::CString(buf);
	}

	// Auto-start: red4ext\plugins\MCPassthrough\autostart.txt names the command that starts the Minecraft half (first
	// non-comment line; "delay=<seconds>" waits that long after the game starts, so Minecraft doesn't land on the
	// game's own start-up memory spike). Skipped when Minecraft's link already answers. The process goes into a job
	// object that kills everything in it when the job's handle closes: Minecraft closes with the game, crashes included.
	const RED4ext::v1::Sdk *g_sdk = nullptr;
	RED4ext::v1::PluginHandle g_handle = nullptr;
	HANDLE g_job = nullptr;
	std::thread g_autostartThread;
	std::atomic<bool> g_stopAutostart{false};

	void log_info(const char *msg)
	{
		if (g_sdk && g_sdk->logger)
			g_sdk->logger->Info(g_handle, msg);
	}

	bool link_answers()
	{
		WSADATA wsa;
		WSAStartup(MAKEWORD(2, 2), &wsa);
		SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
		bool ok = false;
		if (s != INVALID_SOCKET)
		{
			sockaddr_in addr{};
			addr.sin_family = AF_INET;
			addr.sin_port = htons(kPort);
			addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
			ok = connect(s, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0;
			closesocket(s);
		}
		WSACleanup();
		return ok;
	}

	void autostart_run()
	{
		wchar_t path[MAX_PATH];
		GetModuleFileNameW(g_module, path, MAX_PATH);
		wchar_t *slash = wcsrchr(path, L'\\');
		if (!slash)
			return;
		wcscpy_s(slash + 1, MAX_PATH - (slash + 1 - path), L"autostart.txt");
		FILE *f = nullptr;
		if (_wfopen_s(&f, path, L"r") != 0 || !f)
			return; // no autostart.txt: start Minecraft yourself
		char line[2048];
		std::string command;
		int delay = 20;
		while (fgets(line, sizeof(line), f))
		{
			std::string l(line);
			while (!l.empty() && (l.back() == '\n' || l.back() == '\r' || l.back() == ' '))
				l.pop_back();
			if (l.empty() || l[0] == '#')
				continue;
			if (l.rfind("delay=", 0) == 0)
				delay = std::atoi(l.c_str() + 6);
			else if (command.empty())
				command = l;
		}
		fclose(f);
		if (command.empty())
			return;
		for (int i = 0; i < delay * 10 && !g_stopAutostart; ++i)
			Sleep(100);
		if (g_stopAutostart)
			return;
		if (link_answers())
		{
			log_info("autostart: Minecraft is already running");
			return;
		}
		g_job = CreateJobObjectW(nullptr, nullptr);
		if (g_job)
		{
			JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
			limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
			SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
		}
		std::wstring cmd(command.begin(), command.end());
		STARTUPINFOW si{};
		si.cb = sizeof(si);
		PROCESS_INFORMATION pi{};
		if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &si, &pi))
		{
			log_info("autostart: couldn't start the command in autostart.txt");
			return;
		}
		if (g_job)
			AssignProcessToJobObject(g_job, pi.hProcess);
		ResumeThread(pi.hThread);
		CloseHandle(pi.hThread);
		CloseHandle(pi.hProcess);
		log_info("autostart: started Minecraft (it closes with the game)");
	}

	template <typename Fn>
	void add_global(RED4ext::CRTTISystem *rtti, const char *name, Fn fn, const char *param, const char *ret)
	{
		auto *f = RED4ext::CGlobalFunction::Create(name, name, fn);
		f->flags = {.isNative = true, .isStatic = true};
		if (param)
			f->AddParam("String", param);
		f->SetReturnType(ret);
		rtti->RegisterFunction(f);
	}

	// String is only resolvable in the post-register pass (in the register pass the parameter is silently dropped).
	void PostRegisterTypes()
	{
		auto *rtti = RED4ext::CRTTISystem::Get();
		add_global(rtti, "MCPT_Send", &MCPT_Send, "message", "Bool");
		add_global(rtti, "MCPT_Poll", &MCPT_Poll, nullptr, "String");
		add_global(rtti, "MCPT_Pose", &MCPT_Pose, "spec", "Bool");
		add_global(rtti, "MCPT_Status", &MCPT_Status, nullptr, "String");
		add_global(rtti, "MCPT_Input", &MCPT_Input, "capture", "String");
	}

	void RegisterTypes()
	{
	}
}

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle handle, RED4ext::v1::EMainReason reason, const RED4ext::v1::Sdk *sdk)
{
	HMODULE user32 = GetModuleHandleW(L"user32.dll");
	void *rawData = user32 ? reinterpret_cast<void *>(GetProcAddress(user32, "GetRawInputData")) : nullptr;
	void *rawBuffer = user32 ? reinterpret_cast<void *>(GetProcAddress(user32, "GetRawInputBuffer")) : nullptr;
	switch (reason)
	{
	case RED4ext::v1::EMainReason::Load:
	{
		g_sdk = sdk;
		g_handle = handle;
		if (sdk && sdk->hooking && rawData && rawBuffer)
		{
			sdk->hooking->Attach(handle, rawData, reinterpret_cast<void *>(&hook_GetRawInputData), reinterpret_cast<void **>(&g_origGetRawInputData));
			sdk->hooking->Attach(handle, rawBuffer, reinterpret_cast<void *>(&hook_GetRawInputBuffer),
				reinterpret_cast<void **>(&g_origGetRawInputBuffer));
		}
		GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			reinterpret_cast<LPCWSTR>(&ensure_started), &g_module);
		g_autostartThread = std::thread(autostart_run);
		auto *rtti = RED4ext::CRTTISystem::Get();
		rtti->AddRegisterCallback(RegisterTypes);
		rtti->AddPostRegisterCallback(PostRegisterTypes);
		break;
	}
	case RED4ext::v1::EMainReason::Unload:
		compositor::unregister(g_module);
		stop_input();
		g_stopAutostart = true;
		if (g_autostartThread.joinable())
			g_autostartThread.join();
		if (g_job)
		{
			CloseHandle(g_job); // closes the Minecraft we started
			g_job = nullptr;
		}
		if (sdk && sdk->hooking)
		{
			if (rawData && g_origGetRawInputData)
				sdk->hooking->Detach(handle, rawData);
			if (rawBuffer && g_origGetRawInputBuffer)
				sdk->hooking->Detach(handle, rawBuffer);
		}
		if (g_wsStarted)
			g_ws.stop();
		break;
	}
	return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo *info)
{
	info->name = L"MCPassthrough";
	info->author = L"universal-modder";
	info->version = RED4EXT_V1_SEMVER(0, 1, 0);
	info->runtime = RED4EXT_V1_RUNTIME_VERSION_LATEST;
	info->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
	return RED4EXT_API_VERSION_1;
}
