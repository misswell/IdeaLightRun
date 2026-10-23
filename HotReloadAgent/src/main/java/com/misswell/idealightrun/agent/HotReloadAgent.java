package com.misswell.idealightrun.agent;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.lang.instrument.ClassDefinition;
import java.lang.instrument.Instrumentation;
import java.lang.instrument.UnmodifiableClassException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermission;
import java.security.CodeSource;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.Collections;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Semaphore;

/**
 * IdeaLightRun 的标准 Java Agent（无 JDWP）。
 *
 * 能力边界：只使用 JVM 标准的 Instrumentation#redefineClasses，因此只能替换
 * 已加载类的方法体；字段 / 方法 / 继承结构变更、删除类会被 JVM 拒绝，必须
 * 如实返回失败，不能把“部分字节码写进去了”当成成功。
 *
 * 控制通道：只绑定 127.0.0.1 的随机端口；token 从 0600 文件读取，不写入进程
 * 参数或日志；端口通过原子写入的 0600 文件交给宿主。
 */
public final class HotReloadAgent {
    private static final int MAGIC = 0x494C5231; // "ILR1"
    private static final int MAX_FRAME_BYTES = 64 * 1024 * 1024;
    private static final int MAX_STRING_BYTES = 8 * 1024;
    private static final int MAX_CLASSES_PER_REQUEST = 100_000;
    private static final int MAX_CONNECTIONS = 4;

    private static final int OP_STATUS = 1;
    private static final int OP_RELOAD = 2;
    private static final int OP_SHUTDOWN = 3;

    private static final int STATUS_OK = 0;
    private static final int STATUS_PARTIAL = 1;
    private static final int STATUS_ERROR = 2;
    private static final int STATUS_UNAUTHORIZED = 3;

    private static final int CLASS_APPLIED = 0;
    private static final int CLASS_FAILED = 1;
    private static final int CLASS_SKIPPED = 2;

    private static final Semaphore CONNECTIONS = new Semaphore(MAX_CONNECTIONS);
    private static volatile ServerSocket serverSocket;
    private static volatile boolean running = false;

    private HotReloadAgent() {}

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        try {
            start(agentArgs, instrumentation);
        } catch (Throwable failure) {
            // 不输出 token 或完整参数；宿主会因端口文件缺失给出明确错误。
            System.err.println("[IdeaLightRun] HotReloadAgent 启动失败：" + failure);
        }
    }

    private static void start(String agentArgs, Instrumentation instrumentation) throws IOException {
        if (instrumentation == null) {
            throw new IllegalStateException("Instrumentation 不可用");
        }
        Map<String, String> options = parseOptions(agentArgs);
        String portFile = options.get("portFile");
        String tokenFile = options.get("tokenFile");
        if (portFile == null || portFile.isEmpty() || tokenFile == null || tokenFile.isEmpty()) {
            throw new IllegalArgumentException("缺少 portFile / tokenFile 参数");
        }

        String token = new String(
            Files.readAllBytes(Paths.get(tokenFile)),
            StandardCharsets.UTF_8
        ).trim();
        if (token.isEmpty()) {
            throw new IllegalArgumentException("控制凭据为空");
        }

        ServerSocket server = new ServerSocket();
        server.setReuseAddress(false);
        server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 4);
        serverSocket = server;
        running = true;
        writePortFile(Paths.get(portFile), server.getLocalPort());

        Thread acceptThread = new Thread(
            new Acceptor(server, token, instrumentation),
            "IdeaLightRun-HotReload-Acceptor"
        );
        acceptThread.setDaemon(true);
        acceptThread.start();

        System.err.println(
            "[IdeaLightRun] HotReloadAgent 已监听 127.0.0.1:" + server.getLocalPort()
        );
    }

    private static Map<String, String> parseOptions(String agentArgs) {
        Map<String, String> result = new HashMap<String, String>();
        if (agentArgs == null) {
            return result;
        }
        String[] parts = agentArgs.split(",");
        for (String part : parts) {
            int index = part.indexOf('=');
            if (index <= 0) {
                continue;
            }
            String key = part.substring(0, index).trim();
            String value = part.substring(index + 1).trim();
            if (!key.isEmpty()) {
                result.put(key, value);
            }
        }
        return result;
    }

    /** 先写临时文件再原子改名，宿主轮询时不会读到空文件或半个端口号。 */
    private static void writePortFile(Path portFile, int port) throws IOException {
        Path directory = portFile.toAbsolutePath().getParent();
        if (directory != null) {
            Files.createDirectories(directory);
        }
        Path temporary = portFile.resolveSibling(portFile.getFileName().toString() + ".tmp");
        Files.write(
            temporary,
            String.valueOf(port).getBytes(StandardCharsets.US_ASCII),
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING,
            StandardOpenOption.WRITE
        );
        restrictPermissions(temporary);
        try {
            Files.move(
                temporary,
                portFile,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING
            );
        } catch (AtomicMoveNotSupportedException unsupported) {
            Files.move(temporary, portFile, StandardCopyOption.REPLACE_EXISTING);
        }
        restrictPermissions(portFile);
    }

    private static void restrictPermissions(Path path) {
        try {
            Set<PosixFilePermission> permissions = EnumSet.of(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE
            );
            Files.setPosixFilePermissions(path, permissions);
        } catch (Throwable ignored) {
            // 非 POSIX 文件系统上尽力而为；控制目录本身已是 0700。
        }
    }

    private static void stopServer() {
        running = false;
        ServerSocket server = serverSocket;
        serverSocket = null;
        if (server != null) {
            try {
                server.close();
            } catch (IOException ignored) {
                // 关闭失败不影响宿主退出。
            }
        }
    }

    private static final class Acceptor implements Runnable {
        private final ServerSocket server;
        private final String token;
        private final Instrumentation instrumentation;

        Acceptor(ServerSocket server, String token, Instrumentation instrumentation) {
            this.server = server;
            this.token = token;
            this.instrumentation = instrumentation;
        }

        @Override
        public void run() {
            while (running && !server.isClosed()) {
                Socket socket;
                try {
                    socket = server.accept();
                } catch (SocketException closed) {
                    return;
                } catch (IOException failure) {
                    if (!running) {
                        return;
                    }
                    System.err.println("[IdeaLightRun] HotReloadAgent 接受连接失败：" + failure);
                    continue;
                }

                if (!CONNECTIONS.tryAcquire()) {
                    closeQuietly(socket);
                    continue;
                }
                Thread worker = new Thread(
                    new ConnectionHandler(socket, token, instrumentation),
                    "IdeaLightRun-HotReload-Connection"
                );
                worker.setDaemon(true);
                worker.start();
            }
        }
    }

    private static final class ConnectionHandler implements Runnable {
        private final Socket socket;
        private final String token;
        private final Instrumentation instrumentation;

        ConnectionHandler(Socket socket, String token, Instrumentation instrumentation) {
            this.socket = socket;
            this.token = token;
            this.instrumentation = instrumentation;
        }

        @Override
        public void run() {
            DataInputStream input = null;
            DataOutputStream output = null;
            try {
                socket.setTcpNoDelay(true);
                input = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
                output = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));

                while (running) {
                    int magic;
                    try {
                        magic = input.readInt();
                    } catch (EOFException endOfStream) {
                        return;
                    }
                    if (magic != MAGIC) {
                        return;
                    }
                    String requestToken = readString(input);
                    int opcode = input.readUnsignedByte();

                    if (!isAuthorized(token, requestToken)) {
                        writeResponse(output, STATUS_UNAUTHORIZED, "unauthorized", new ArrayList<ClassResult>());
                        return;
                    }

                    switch (opcode) {
                        case OP_STATUS:
                            writeResponse(
                                output,
                                STATUS_OK,
                                statusMessage(instrumentation),
                                new ArrayList<ClassResult>()
                            );
                            break;
                        case OP_RELOAD:
                            handleReload(input, output);
                            break;
                        case OP_SHUTDOWN:
                            writeResponse(
                                output,
                                STATUS_OK,
                                "control channel closing",
                                new ArrayList<ClassResult>()
                            );
                            stopServer();
                            return;
                        default:
                            writeResponse(
                                output,
                                STATUS_ERROR,
                                "unknown opcode " + opcode,
                                new ArrayList<ClassResult>()
                            );
                            return;
                    }
                }
            } catch (IOException failure) {
                // 宿主停止 / socket 被关闭都会走到这里；不记录请求内容。
            } finally {
                closeQuietly(socket);
                CONNECTIONS.release();
            }
        }

        private void handleReload(DataInputStream input, DataOutputStream output) throws IOException {
            int count = input.readInt();
            if (count < 0 || count > MAX_CLASSES_PER_REQUEST) {
                writeResponse(output, STATUS_ERROR, "invalid class count", new ArrayList<ClassResult>());
                return;
            }

            List<ClassRequest> requests = new ArrayList<ClassRequest>(count);
            for (int index = 0; index < count; index++) {
                String className = readString(input);
                String path = readString(input);
                String origin = readString(input);
                requests.add(new ClassRequest(className, path, origin));
            }

            ClassResult[] results = new ClassResult[requests.size()];
            String[] appliedMessages = new String[requests.size()];
            List<ClassDefinition> definitions = new ArrayList<ClassDefinition>();
            Set<Class<?>> scheduled = Collections.newSetFromMap(
                new IdentityHashMap<Class<?>, Boolean>()
            );
            boolean blockingFailure = false;
            String blockingReason = null;

            for (int index = 0; index < requests.size(); index++) {
                ClassRequest request = requests.get(index);
                Resolution resolution = resolve(instrumentation, request);
                if (resolution.failure != null) {
                    results[index] = ClassResult.failed(
                        request.className,
                        request.path,
                        resolution.failure
                    );
                    if (!blockingFailure) {
                        blockingReason = request.className + ": " + resolution.failure;
                    }
                    blockingFailure = true;
                } else if (resolution.targets == null) {
                    results[index] = ClassResult.skipped(
                        request.className,
                        request.path,
                        resolution.message
                    );
                } else {
                    for (Class<?> target : resolution.targets) {
                        // 同一 Class 对象只能交给 redefineClasses 一次。
                        if (scheduled.add(target)) {
                            definitions.add(new ClassDefinition(target, resolution.bytecode));
                        }
                    }
                    appliedMessages[index] = resolution.message;
                }
            }

            if (blockingFailure) {
                // 组内有一个类连“改哪个/能不能改”都无法确定时，整组都不发送；
                // 不能先应用一半再告诉用户需要重启。
                for (int index = 0; index < requests.size(); index++) {
                    if (appliedMessages[index] != null) {
                        results[index] = ClassResult.failed(
                            requests.get(index).className,
                            requests.get(index).path,
                            "atomic group not applied: " + blockingReason
                        );
                    }
                }
            } else if (!definitions.isEmpty()) {
                try {
                    // JVM 保证 redefineClasses 的整组重定义是原子的：
                    // 任一类的字节码被拒绝，所有类都保持旧定义。
                    instrumentation.redefineClasses(
                        definitions.toArray(new ClassDefinition[definitions.size()])
                    );
                    for (int index = 0; index < requests.size(); index++) {
                        if (appliedMessages[index] != null) {
                            results[index] = ClassResult.applied(
                                requests.get(index).className,
                                requests.get(index).path,
                                appliedMessages[index]
                            );
                        }
                    }
                } catch (Throwable failure) {
                    // 单类请求保留具体原因（schema / 字节码被拒），多类请求强调
                    // “整组未应用”，避免把同组里被牵连的类误报成自身结构变更。
                    String message = definitions.size() == 1
                        ? "redefinition failed; class was not applied: " + describe(failure)
                        : "atomic group redefinition failed; no classes were applied: "
                            + describe(failure);
                    for (int index = 0; index < requests.size(); index++) {
                        if (appliedMessages[index] != null) {
                            results[index] = ClassResult.failed(
                                requests.get(index).className,
                                requests.get(index).path,
                                message
                            );
                        }
                    }
                }
            }

            List<ClassResult> ordered = new ArrayList<ClassResult>(requests.size());
            int applied = 0;
            int failed = 0;
            int skipped = 0;
            for (int index = 0; index < requests.size(); index++) {
                ClassResult result = results[index];
                if (result == null) {
                    result = ClassResult.failed(
                        requests.get(index).className,
                        requests.get(index).path,
                        "internal error: no result"
                    );
                }
                ordered.add(result);
                if (result.code == CLASS_APPLIED) {
                    applied++;
                } else if (result.code == CLASS_FAILED) {
                    failed++;
                } else {
                    skipped++;
                }
            }

            String summary = "applied=" + applied + ", failed=" + failed + ", skipped=" + skipped;
            int status = failed == 0 && skipped == 0 ? STATUS_OK : STATUS_PARTIAL;
            writeResponse(output, status, summary, ordered);
        }
    }

    /**
     * 解析一个请求要重定义哪些已加载类。
     *
     * 同一个全限定类名可能被多个 ClassLoader 各加载一份；按名字取第一个会改错。
     * 这里用 CodeSource 与请求的输出目录匹配：
     * - 唯一副本：直接用（没有 CodeSource 时只能接受）；
     * - 多副本：只改来源等于该输出目录的副本；来源全部未知或无法唯一确认时返回歧义错误。
     * 多个来源相同的副本会一起加入整组原子重定义。
     */
    private static Resolution resolve(Instrumentation instrumentation, ClassRequest request) {
        if (request.className == null || request.className.isEmpty()) {
            return Resolution.failed("empty class name");
        }
        if (request.path == null || request.path.isEmpty()) {
            return Resolution.failed("class file path missing");
        }

        List<Class<?>> copies = new ArrayList<Class<?>>();
        for (Class<?> loaded : instrumentation.getAllLoadedClasses()) {
            if (request.className.equals(loaded.getName())) {
                copies.add(loaded);
            }
        }
        if (copies.isEmpty()) {
            return Resolution.skipped("class not loaded");
        }

        String origin = normalizePath(request.origin);
        if (origin == null) {
            origin = deriveOrigin(request.className, request.path);
        }

        List<Class<?>> targets = new ArrayList<Class<?>>();
        List<String> descriptions = new ArrayList<String>();
        boolean hasUnknownOrigin = false;

        if (copies.size() == 1) {
            Class<?> only = copies.get(0);
            String source = codeSourcePath(only);
            if (source != null && origin != null && !samePath(source, origin)) {
                return Resolution.failed(
                    "origin mismatch: class is loaded from " + source + ", requested " + origin
                );
            }
            targets.add(only);
            descriptions.add(describe(only, source));
        } else {
            if (origin == null) {
                return Resolution.failed(
                    "ambiguous: " + copies.size()
                        + " loaded copies and no output root to match; refusing to guess"
                );
            }
            for (Class<?> copy : copies) {
                String source = codeSourcePath(copy);
                descriptions.add(describe(copy, source));
                if (source == null) {
                    hasUnknownOrigin = true;
                } else if (samePath(source, origin)) {
                    targets.add(copy);
                }
            }
            if (targets.isEmpty()) {
                if (hasUnknownOrigin) {
                    return Resolution.failed(
                        "ambiguous: " + copies.size()
                            + " loaded copies, some without CodeSource; cannot uniquely match "
                            + origin + " (" + join(descriptions) + ")"
                    );
                }
                return Resolution.failed(
                    "origin mismatch: loaded copies are " + join(descriptions)
                        + ", requested " + origin
                );
            }
            if (hasUnknownOrigin) {
                return Resolution.failed(
                    "ambiguous: besides " + origin + ", there are loaded copies without CodeSource ("
                        + join(descriptions) + "); refusing to guess"
                );
            }
        }

        for (Class<?> target : targets) {
            if (!instrumentation.isModifiableClass(target)) {
                return Resolution.failed(
                    "class is not modifiable (" + describe(target, codeSourcePath(target)) + ")"
                );
            }
        }

        byte[] bytecode;
        try {
            bytecode = Files.readAllBytes(Paths.get(request.path));
        } catch (IOException failure) {
            return Resolution.failed("cannot read class file: " + failure);
        } catch (Throwable failure) {
            return Resolution.failed("cannot read class file: " + failure);
        }

        String message = "redefined atomically from " + (origin == null ? "<unknown>" : origin);
        if (targets.size() > 1) {
            message += " (" + targets.size() + " loaded copies)";
        }
        return Resolution.resolved(targets, bytecode, message);
    }

    private static String codeSourcePath(Class<?> clazz) {
        try {
            ProtectionDomain domain = clazz.getProtectionDomain();
            if (domain == null) {
                return null;
            }
            CodeSource source = domain.getCodeSource();
            if (source == null) {
                return null;
            }
            URL location = source.getLocation();
            if (location == null || !"file".equalsIgnoreCase(location.getProtocol())) {
                return null;
            }
            return canonicalPath(Paths.get(location.toURI()));
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static String deriveOrigin(String className, String classFile) {
        String relative = className.replace('.', '/') + ".class";
        String normalized = classFile.replace('\\', '/');
        String suffix = "/" + relative;
        if (normalized.endsWith(suffix)) {
            return normalized.substring(0, normalized.length() - suffix.length());
        }
        return null;
    }

    private static String normalizePath(String path) {
        if (path == null || path.isEmpty()) {
            return null;
        }
        try {
            return canonicalPath(Paths.get(path));
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static String canonicalPath(Path path) {
        try {
            return path.toRealPath().toString();
        } catch (Throwable ignored) {
            return path.toAbsolutePath().normalize().toString();
        }
    }

    private static boolean samePath(String first, String second) {
        return canonicalPath(Paths.get(first)).equals(canonicalPath(Paths.get(second)));
    }

    private static String describe(Class<?> clazz, String source) {
        ClassLoader loader = clazz.getClassLoader();
        String loaderName = loader == null ? "bootstrap" : loader.getClass().getName();
        return loaderName + " -> " + (source == null ? "<unknown>" : source);
    }

    private static String describe(Throwable failure) {
        String message = failure.getMessage();
        return failure.getClass().getName() + (message == null ? "" : ": " + message);
    }

    private static String join(List<String> values) {
        StringBuilder builder = new StringBuilder();
        for (int index = 0; index < values.size(); index++) {
            if (index > 0) {
                builder.append("; ");
            }
            builder.append(values.get(index));
        }
        return builder.toString();
    }

    private static String statusMessage(Instrumentation instrumentation) {
        int loaded = instrumentation.getAllLoadedClasses().length;
        return "agent ready; java.version=" + System.getProperty("java.version")
            + "; vm=" + System.getProperty("java.vm.name")
            + "; loaded_classes=" + loaded;
    }

    private static boolean isAuthorized(String expected, String received) {
        if (expected == null || received == null) {
            return false;
        }
        return MessageDigest.isEqual(
            expected.getBytes(StandardCharsets.UTF_8),
            received.getBytes(StandardCharsets.UTF_8)
        );
    }

    private static String readString(DataInputStream input) throws IOException {
        int length = input.readInt();
        if (length < 0 || length > MAX_STRING_BYTES) {
            throw new IOException("string length out of range");
        }
        if (length > MAX_FRAME_BYTES) {
            throw new IOException("frame too large");
        }
        byte[] bytes = new byte[length];
        input.readFully(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static void writeString(DataOutputStream output, String value) throws IOException {
        byte[] bytes = value == null
            ? new byte[0]
            : value.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_STRING_BYTES) {
            bytes = new byte[0];
        }
        output.writeInt(bytes.length);
        output.write(bytes);
    }

    private static void writeResponse(
        DataOutputStream output,
        int status,
        String message,
        List<ClassResult> results
    ) throws IOException {
        output.writeInt(MAGIC);
        output.writeByte(status);
        writeString(output, message);
        output.writeInt(results.size());
        for (ClassResult result : results) {
            writeString(output, result.className);
            writeString(output, result.path);
            output.writeByte(result.code);
            writeString(output, result.message);
        }
        output.flush();
    }

    private static void closeQuietly(Socket socket) {
        try {
            socket.close();
        } catch (IOException ignored) {
            // 已关闭 / 对端断开都是正常收尾。
        }
    }

    private static final class ClassRequest {
        final String className;
        final String path;
        final String origin;

        ClassRequest(String className, String path, String origin) {
            this.className = className;
            this.path = path;
            this.origin = origin;
        }
    }

    /**
     * 一个请求的解析结果：要么给出要一起重定义的 Class 对象和字节码，
     * 要么是“类尚未加载”的跳过，要么是必须阻止整组提交的失败原因。
     */
    private static final class Resolution {
        final List<Class<?>> targets;
        final byte[] bytecode;
        final String message;
        final String failure;

        private Resolution(List<Class<?>> targets, byte[] bytecode, String message, String failure) {
            this.targets = targets;
            this.bytecode = bytecode;
            this.message = message;
            this.failure = failure;
        }

        static Resolution resolved(List<Class<?>> targets, byte[] bytecode, String message) {
            return new Resolution(targets, bytecode, message, null);
        }

        static Resolution skipped(String message) {
            return new Resolution(null, null, message, null);
        }

        static Resolution failed(String failure) {
            return new Resolution(null, null, failure, failure);
        }
    }

    private static final class ClassResult {
        final String className;
        final String path;
        final int code;
        final String message;

        ClassResult(String className, String path, int code, String message) {
            this.className = className;
            this.path = path;
            this.code = code;
            this.message = message;
        }

        static ClassResult applied(String className, String path, String message) {
            return new ClassResult(className, path, CLASS_APPLIED, message);
        }

        static ClassResult failed(String className, String path, String message) {
            return new ClassResult(className, path, CLASS_FAILED, message);
        }

        static ClassResult skipped(String className, String path, String message) {
            return new ClassResult(className, path, CLASS_SKIPPED, message);
        }
    }
}
