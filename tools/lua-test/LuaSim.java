// Runs the mod's Lua in Kahlua, the Lua VM of Project Zomboid, outside the game.
//
//   java -cp <ProjectZomboid>/projectzomboid.jar LuaSim.java <mod lua dir> <sim.lua>
//
// The working directory must contain the game's stdlib.lua (tools/test-lua.ps1 does it).
// Step 1 compiles every .lua file (syntax). Step 2 runs sim.lua, which loads the mod files
// with a fake game API and checks the window, the translations and the caps.

import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaCallFrame;
import se.krka.kahlua.vm.LuaClosure;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;

public class LuaSim {
    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: LuaSim <mod lua dir> <sim.lua>");
            System.exit(2);
        }
        Path root = Path.of(args[0]).toAbsolutePath().normalize();
        Path sim = Path.of(args[1]).toAbsolutePath().normalize();
        J2SEPlatform platform = new J2SEPlatform();

        List<Path> files;
        try (Stream<Path> s = Files.walk(root)) {
            files = s.filter(p -> p.toString().endsWith(".lua")).sorted().toList();
        }
        int bad = 0;
        for (Path f : files) {
            String rel = root.relativize(f).toString().replace('\\', '/');
            try {
                LuaCompiler.loadstring(Files.readString(f, StandardCharsets.UTF_8), rel, platform.newEnvironment());
                System.out.println("syntax ok    " + rel);
            } catch (Throwable e) {
                bad++;
                System.out.println("SYNTAX ERROR " + rel + ": " + e.getMessage());
            }
        }
        if (bad > 0) {
            System.out.println(bad + " file(s) do not compile");
            System.exit(1);
        }

        KahluaTable env = platform.newEnvironment();
        KahluaThread thread = new KahluaThread(System.out, platform, env);
        thread.debugOwnerThread = Thread.currentThread(); // checked by the game's Kahlua fork
        env.rawset("__MOD_ROOT", root.toString().replace('\\', '/'));
        // __LUA_FILES = { "client/Talky/Talky_Actions.lua", ... } (sorted, like the game's load order)
        KahluaTable list = platform.newTable();
        for (int i = 0; i < files.size(); i++) {
            list.rawset(i + 1, root.relativize(files.get(i)).toString().replace('\\', '/'));
        }
        env.rawset("__LUA_FILES", list);
        // __readFile(path) -> content or nil
        env.rawset("__readFile", (JavaFunction) (LuaCallFrame frame, int n) -> {
            try {
                return frame.push(Files.readString(Path.of((String) frame.get(0)), StandardCharsets.UTF_8));
            } catch (Exception e) {
                return frame.pushNil();
            }
        });
        LuaClosure closure = LuaCompiler.loadstring(Files.readString(sim, StandardCharsets.UTF_8), "sim.lua", env);
        Object[] result = thread.pcall(closure, new Object[0]);
        boolean ok = result.length > 0 && Boolean.TRUE.equals(result[0]);
        if (!ok) {
            System.out.println("sim.lua failed:");
            for (int i = 1; i < result.length; i++) System.out.println("  " + result[i]);
            System.exit(1);
        }
        Object failures = env.rawget("__FAILURES");
        if (failures instanceof Double d && d > 0) System.exit(1);
    }
}
