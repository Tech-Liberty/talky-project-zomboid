// Runs the mod's Lua in Kahlua, the Lua VM of Project Zomboid, outside the game.
//
//   java -cp <ProjectZomboid>/projectzomboid.jar LuaSim.java <mod lua dir> <sim.lua>
//
// The working directory must contain the game's stdlib.lua (tools/test-lua.ps1 does it).
// Step 1 compiles every .lua file (syntax). Step 2 runs sim.lua, the test director, which
// builds one Lua state per simulated game process (single player game, dedicated server,
// each client) and loads the mod files into them. sim.lua gets these globals:
//   __MOD_ROOT    the mod's media/lua folder        __MOD_MEDIA  its media folder
//   __TEST_DIR    the folder of sim.lua             __LUA_FILES  { "client/Talky/x.lua", ... }
//                 (sorted case-insensitively, like the game's load order)
//   __readFile(path)              -> text, or nil
//   __newEnv()                    -> a new global table with the standard library: one Lua
//                                    state of its own (nothing is shared with the others)
//   __load(env, path, chunkName)  -> a function running the file with env as its globals,
//                                    or nil and the compile error
//   __netCopy(table)              -> copy, dropped, sent: the table as the other side of the
//                                    network receives it (written and read back by the game's
//                                    own serializer, zombie.network.TableNetworkUtils, in a
//                                    buffer of the game's size: an overflow throws, as in the
//                                    game), how many values were fake game objects the game
//                                    does not send (tables whose metatable has __java: IsoPlayer,
//                                    IsoZombie...), and how many were fake IsoDirections, which
//                                    the game DOES send (TableNetworkUtils.getValueByte: also
//                                    InventoryItem and IsoDeadBody, which need the game's world
//                                    and are not simulated). Those are replaced with the real
//                                    enum constant (zombie.iso.IsoDirections): the receiver gets
//                                    a Java object, type "userdata" in Lua, like in the game.
//   __NET_COPY                    -> "TableNetworkUtils", or "copy" when the game class could
//                                    not be used or -Dtalky.netcopy=copy is set (same rules,
//                                    written here: no game object, no InventoryItem)
// The game serializer writes strings with zombie.GameWindow, whose class loads LWJGL: run java
// with --enable-native-access=ALL-UNNAMED to silence the JDK warning about it.
// The run fails when sim.lua raises an error or sets __FAILURES above 0.

import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableIterator;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaCallFrame;
import se.krka.kahlua.vm.LuaClosure;

import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Stream;

public class LuaSim {
    static J2SEPlatform platform;

    // zombie.network.TableNetworkUtils save/load, found by reflection so a missing class only
    // switches to the local copy.
    static Method netSave, netLoad;
    static java.lang.reflect.Constructor<?> writerCtor, readerCtor;
    static String netMode = "copy";
    // zombie.iso.IsoDirections, the one kind of game object the tests deliver as a real one
    @SuppressWarnings("rawtypes")
    static Class<? extends Enum> dirClass;

    // The packet buffer of a game connection holds 1,000,000 bytes (UdpConnection, never grown);
    // the packet type, the player byte, putUTF(module), putUTF(command) and the hasTable byte
    // come before the table.
    static final int NET_BUFFER = 1000000 - 64;

    @SuppressWarnings({ "unchecked", "rawtypes" })
    static void initDirections() {
        try {
            Class<?> c = Class.forName("zombie.iso.IsoDirections");
            Enum.valueOf((Class) c, "N");
            dirClass = (Class<? extends Enum>) c;
        } catch (Throwable e) {
            dirClass = null;
            System.out.println("note: zombie.iso.IsoDirections not usable (" + e + "), fake directions are dropped");
        }
    }

    @SuppressWarnings({ "unchecked", "rawtypes" })
    static Object realDirection(KahluaTable fake) {
        Object name = fake.rawget("name");
        try {
            return Enum.valueOf((Class) dirClass, name instanceof String s ? s : "N");
        } catch (IllegalArgumentException e) {
            return Enum.valueOf((Class) dirClass, "N");
        }
    }

    static void initNet() {
        if ("copy".equals(System.getProperty("talky.netcopy"))) {
            System.out.println("note: -Dtalky.netcopy=copy, network args copied by LuaSim");
            return;
        }
        try {
            Class<?> tnu = Class.forName("zombie.network.TableNetworkUtils");
            Class<?> w = Class.forName("zombie.core.network.ByteBufferWriter");
            Class<?> r = Class.forName("zombie.core.network.ByteBufferReader");
            netSave = tnu.getMethod("save", KahluaTable.class, w);
            netLoad = tnu.getMethod("load", KahluaTable.class, r);
            writerCtor = w.getConstructor(ByteBuffer.class);
            readerCtor = r.getConstructor(ByteBuffer.class);
            // nested tables are created with LuaManager.platform
            Class<?> lm = Class.forName("zombie.Lua.LuaManager");
            if (lm.getField("platform").get(null) == null) lm.getField("platform").set(null, platform);
            KahluaTable probe = platform.newTable();
            probe.rawset("a", 1.0);
            KahluaTable back = roundTrip(probe);
            if (back == null || !Double.valueOf(1.0).equals(back.rawget("a"))) throw new IllegalStateException("round trip");
            netMode = "TableNetworkUtils";
        } catch (Throwable e) {
            netSave = null;
            netMode = "copy";
            System.out.println("note: zombie.network.TableNetworkUtils not usable (" + e + "), network args copied by LuaSim");
        }
    }

    static KahluaTable roundTrip(KahluaTable t) throws Exception {
        ByteBuffer bb = ByteBuffer.allocate(NET_BUFFER);
        netSave.invoke(null, t, writerCtor.newInstance(bb));
        bb.flip();
        KahluaTable out = platform.newTable();
        netLoad.invoke(null, out, readerCtor.newInstance(bb));
        return out;
    }

    static boolean isJavaObject(KahluaTable t) {
        Object mt = t.getMetatable();
        return mt instanceof KahluaTable m && m.rawget("__java") != null;
    }

    static String javaKind(KahluaTable t) {
        return t.getMetatable() instanceof KahluaTable m && m.rawget("__java") instanceof String s ? s : null;
    }

    // Keys string or number; values string, number, boolean or table. Fake game objects are
    // dropped and counted (dropped), except IsoDirections: replaced with the real enum constant
    // and counted (sent). Cycles and very deep tables are an error.
    static KahluaTable plain(KahluaTable t, int depth, int[] dropped, int[] sent) {
        if (depth > 40) throw new IllegalStateException("network args nested too deep (or a cycle)");
        KahluaTable out = platform.newTable();
        KahluaTableIterator it = t.iterator();
        while (it.advance()) {
            Object k = it.getKey(), v = it.getValue();
            if (!(k instanceof String) && !(k instanceof Double)) continue;
            if (v instanceof String || v instanceof Double || v instanceof Boolean) {
                out.rawset(k, v);
            } else if (v instanceof KahluaTable vt) {
                if (isJavaObject(vt)) {
                    if (dirClass != null && "IsoDirections".equals(javaKind(vt))) {
                        out.rawset(k, realDirection(vt));
                        sent[0]++;
                    } else {
                        dropped[0]++;
                    }
                } else {
                    out.rawset(k, plain(vt, depth + 1, dropped, sent));
                }
            } else if (dirClass != null && dirClass.isInstance(v)) {
                // a real direction received earlier, sent on again
                out.rawset(k, v);
            }
        }
        return out;
    }

    static String rel(Path root, Path f) {
        return root.relativize(f).toString().replace('\\', '/');
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: LuaSim <mod lua dir> <sim.lua>");
            System.exit(2);
        }
        Path root = Path.of(args[0]).toAbsolutePath().normalize();
        Path sim = Path.of(args[1]).toAbsolutePath().normalize();
        platform = new J2SEPlatform();

        List<Path> files;
        try (Stream<Path> s = Files.walk(root)) {
            files = s.filter(p -> p.toString().endsWith(".lua"))
                     .sorted(Comparator.comparing((Path p) -> rel(root, p), String.CASE_INSENSITIVE_ORDER))
                     .toList();
        }
        int bad = 0;
        for (Path f : files) {
            String rel = rel(root, f);
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

        initNet();
        initDirections();

        KahluaTable env = platform.newEnvironment();
        KahluaThread thread = new KahluaThread(System.out, platform, env);
        thread.debugOwnerThread = Thread.currentThread(); // checked by the game's Kahlua fork
        env.rawset("__MOD_ROOT", root.toString().replace('\\', '/'));
        env.rawset("__MOD_MEDIA", root.getParent().toString().replace('\\', '/'));
        env.rawset("__TEST_DIR", sim.getParent().toString().replace('\\', '/'));
        env.rawset("__NET_COPY", netMode);
        KahluaTable list = platform.newTable();
        for (int i = 0; i < files.size(); i++) list.rawset(i + 1, rel(root, files.get(i)));
        env.rawset("__LUA_FILES", list);

        env.rawset("__readFile", (JavaFunction) (LuaCallFrame frame, int n) -> {
            try {
                return frame.push(Files.readString(Path.of((String) frame.get(0)), StandardCharsets.UTF_8));
            } catch (Exception e) {
                return frame.pushNil();
            }
        });
        env.rawset("__newEnv", (JavaFunction) (LuaCallFrame frame, int n) -> frame.push(platform.newEnvironment()));
        env.rawset("__load", (JavaFunction) (LuaCallFrame frame, int n) -> {
            KahluaTable target = (KahluaTable) frame.get(0);
            String path = (String) frame.get(1);
            String name = n > 2 && frame.get(2) != null ? frame.get(2).toString() : path;
            String src;
            try {
                src = Files.readString(Path.of(path), StandardCharsets.UTF_8);
            } catch (Exception e) {
                return frame.pushNil();
            }
            try {
                return frame.push(LuaCompiler.loadstring(src, name, target));
            } catch (Throwable e) {
                frame.pushNil();
                frame.push(String.valueOf(e.getMessage()));
                return 2;
            }
        });
        env.rawset("__netCopy", (JavaFunction) (LuaCallFrame frame, int n) -> {
            Object a = n > 0 ? frame.get(0) : null;
            if (!(a instanceof KahluaTable t)) return frame.pushNil();
            int[] dropped = { 0 }, sent = { 0 };
            KahluaTable copy = plain(t, 0, dropped, sent);
            if (netSave != null) {
                try {
                    copy = roundTrip(copy);
                } catch (Exception e) {
                    // the game throws too (BufferOverflowException out of sendClientCommand)
                    Throwable cause = e instanceof java.lang.reflect.InvocationTargetException ite && ite.getCause() != null ? ite.getCause() : e;
                    throw new RuntimeException("TableNetworkUtils round trip failed: " + cause);
                }
            }
            frame.push(copy);
            frame.push((double) dropped[0]);
            frame.push((double) sent[0]);
            return 3;
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
