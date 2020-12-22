---
author: sn0rt
comments: true
date: 2020-12-22
layout: post
title: runc 的 create 与 start
tag: k8s
---

前面看过了 `containerd-shim` 调用了 `runc create` 与 `runc start`，这里梳理一下 `runc` 的相关代码逻辑。

## run create --bundle

```go
func startContainer(context *cli.Context, spec *specs.Spec, action CtAct, criuOpts *libcontainer.CriuOpts) (int, error) {
	id := context.Args().First()
	if id == "" {
		return -1, errEmptyID
	}

	notifySocket := newNotifySocket(context, os.Getenv("NOTIFY_SOCKET"), id)
	if notifySocket != nil {
		notifySocket.setupSpec(context, spec)
	}

	container, err := createContainer(context, id, spec) // 准备 container 在 runc 内存中的 object
	if err != nil {
		return -1, err
	}

	if notifySocket != nil {
		err := notifySocket.setupSocket()
		if err != nil {
			return -1, err
		}
	}

	// Support on-demand socket activation by passing file descriptors into the container init process.
	listenFDs := []*os.File{}
	if os.Getenv("LISTEN_FDS") != "" {
		listenFDs = activation.Files(false)
	}

	logLevel := "info"
	if context.GlobalBool("debug") {
		logLevel = "debug"
	}

	r := &runner{
		enableSubreaper: !context.Bool("no-subreaper"),
		shouldDestroy:   true,
		container:       container,
		listenFDs:       listenFDs,
		notifySocket:    notifySocket,
		consoleSocket:   context.String("console-socket"),
		detach:          context.Bool("detach"),
		pidFile:         context.String("pid-file"),
		preserveFDs:     context.Int("preserve-fds"),
		action:          action,
		criuOpts:        criuOpts,
		init:            true,
		logLevel:        logLevel,
	}
	return r.run(spec.Process) // run
}
```

调用 `createContainer`创建 `cotnainer` 对象，实际的创建由平台相关的工厂函数实现

```go
func createContainer(context *cli.Context, id string, spec *specs.Spec) (libcontainer.Container, error) {
	rootlessCg, err := shouldUseRootlessCgroupManager(context)
	if err != nil {
		return nil, err
	}
	config, err := specconv.CreateLibcontainerConfig(&specconv.CreateOpts{
		CgroupName:       id,
		UseSystemdCgroup: context.GlobalBool("systemd-cgroup"),
		NoPivotRoot:      context.Bool("no-pivot"),
		NoNewKeyring:     context.Bool("no-new-keyring"),
		Spec:             spec,
		RootlessEUID:     os.Geteuid() != 0,
		RootlessCgroups:  rootlessCg,
	})
	if err != nil {
		return nil, err
	}

	factory, err := loadFactory(context) // 返回 Linux 的实现 InitPath 字段为 /proc/self/exe ，InitArgs 字段为 []string{os.Args[0], "init"},
	if err != nil {
		return nil, err
	}
	return factory.Create(id, config)
```

`factory.Create` 创建返回一个 `container`结构体，其中 container 结构体

```go
	c := &linuxContainer{
		id:            id,
		root:          containerRoot, //这里是 cotnainer 的 root 目录
		config:        config, 
		initPath:      l.InitPath, // init path /proc/self/exe
		initArgs:      l.InitArgs, // []string{os.Args[0].}
		criuPath:      l.CriuPath,
		newuidmapPath: l.NewuidmapPath,
		newgidmapPath: l.NewgidmapPath,
		cgroupManager: l.NewCgroupsManager(config.Cgroups, nil),
	}
```

返回上述结构体，继续回到到上层代码继续执行到`r.run(spec.Process)`

```go
func (r *runner) run(config *specs.Process) (int, error) {
...
	process, err := newProcess(*config, r.init, r.logLevel)
	if err != nil {
		return -1, err
	}
....

	switch r.action {
	case CT_ACT_CREATE:
		err = r.container.Start(process) // 这次行为会到这个流程
....
```

回到` r.container.Start(process)` 继续执行

```go
func (c *linuxContainer) Start(process *Process) error {
	c.m.Lock()
	defer c.m.Unlock()
	if process.Init { // 使用 create 这里就是 true
		if err := c.createExecFifo(); err != nil { // create 一个 exec.fifo 用与进程间通信, 只有写时会被阻塞，读写都在时才会正常运行
			return err
		}
	}
	if err := c.start(process); err != nil { // 这才是本次关注点
		if process.Init {
			c.deleteExecFifo()
		}
		return err
	}
	return nil
}
```

`c.start(process)`的实现

```go
func (c *linuxContainer) start(process *Process) error {
	parent, err := c.newParentProcess(process) // 创建父进程， 代码在下面 review
	if err != nil {
		return newSystemErrorWithCause(err, "creating new parent process")
	}
	parent.forwardChildLogs()
	if err := parent.start(); err != nil { // 这里创建父进程的 start，其实也就是 runc init
		// terminate the process to ensure that it properly is reaped.
...
```

`newParentProcess()`其实就是命令行为` runc init` 的 `parentProcess`，返回给上面调用`parent.start()`。

```go
func (c *linuxContainer) newParentProcess(p *Process) (parentProcess, error) {
	parentInitPipe, childInitPipe, err := utils.NewSockPair("init")
	if err != nil {
		return nil, newSystemErrorWithCause(err, "creating new init pipe")
	}
	messageSockPair := filePair{parentInitPipe, childInitPipe}

	parentLogPipe, childLogPipe, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("Unable to create the log pipe:  %s", err)
	}
	logFilePair := filePair{parentLogPipe, childLogPipe}

	cmd, err := c.commandTemplate(p, childInitPipe, childLogPipe) // 准备命令行 
	if err != nil {
		return nil, newSystemErrorWithCause(err, "creating new command template")
	}
	if !p.Init {
		return c.newSetnsProcess(p, cmd, messageSockPair, logFilePair) // 如果不是 init ，所以这一次不关心这里
	}

	// We only set up fifoFd if we're not doing a `runc exec`. The historic
	// reason for this is that previously we would pass a dirfd that allowed
	// for container rootfs escape (and not doing it in `runc exec` avoided
	// that problem), but we no longer do that. However, there's no need to do
	// this for `runc exec` so we just keep it this way to be safe.
	if err := c.includeExecFifo(cmd); err != nil {
		return nil, newSystemErrorWithCause(err, "including execfifo in cmd.Exec setup")
	}
	return c.newInitProcess(p, cmd, messageSockPair, logFilePair) // 返回 initProcess，其中 cmd 为 runc init，并 c.initProcess = init
}
```

`parent.start()`  就是实际开始运行 `runc init`了

````go
func (p *initProcess) start() error {
	defer p.messageSockPair.parent.Close()
	err := p.cmd.Start() // 启动 runc init
	p.process.ops = p
	// close the write-side of the pipes (controlled by child)
	p.messageSockPair.child.Close()
	p.logFilePair.child.Close()
	if err != nil {
		p.process.ops = nil
		return newSystemErrorWithCause(err, "starting init process command")
	}
	// Do this before syncing with child so that no children can escape the
	// cgroup. We don't need to worry about not doing this and not being root
	// because we'd be using the rootless cgroup manager in that case.
	if err := p.manager.Apply(p.pid()); err != nil {
		return newSystemErrorWithCause(err, "applying cgroup configuration for process")
	}
	if p.intelRdtManager != nil {
		if err := p.intelRdtManager.Apply(p.pid()); err != nil {
			return newSystemErrorWithCause(err, "applying Intel RDT configuration for process")
		}
	}
	defer func() {
		if err != nil {
			// TODO: should not be the responsibility to call here
			p.manager.Destroy()
			if p.intelRdtManager != nil {
				p.intelRdtManager.Destroy()
			}
		}
	}()

	if _, err := io.Copy(p.messageSockPair.parent, p.bootstrapData); err != nil {
		return newSystemErrorWithCause(err, "copying bootstrap data to pipe")
	}
	childPid, err := p.getChildPid() // 获取 child 的 pid
	if err != nil {
		return newSystemErrorWithCause(err, "getting the final child's pid from pipe")
	}

	// Save the standard descriptor names before the container process
	// can potentially move them (e.g., via dup2()).  If we don't do this now,
	// we won't know at checkpoint time which file descriptor to look up.
	fds, err := getPipeFds(childPid)
	if err != nil {
		return newSystemErrorWithCausef(err, "getting pipe fds for pid %d", childPid)
	}
	p.setExternalDescriptors(fds)
	// Do this before syncing with child so that no children
	// can escape the cgroup
	if err := p.manager.Apply(childPid); err != nil { // 这里设置调用具体的实现配置 cgroup
		return newSystemErrorWithCause(err, "applying cgroup configuration for process")
	}
	if p.intelRdtManager != nil {
		if err := p.intelRdtManager.Apply(childPid); err != nil {
			return newSystemErrorWithCause(err, "applying Intel RDT configuration for process")
		}
	}
	// Now it's time to setup cgroup namesapce
	if p.config.Config.Namespaces.Contains(configs.NEWCGROUP) && p.config.Config.Namespaces.PathOf(configs.NEWCGROUP) == "" {
		if _, err := p.messageSockPair.parent.Write([]byte{createCgroupns}); err != nil {
			return newSystemErrorWithCause(err, "sending synchronization value to init process")
		}
	}

	// Wait for our first child to exit
	if err := p.waitForChildExit(childPid); err != nil {
		return newSystemErrorWithCause(err, "waiting for our first child to exit")
	}

	defer func() {
		if err != nil {
			// TODO: should not be the responsibility to call here
			p.manager.Destroy()
			if p.intelRdtManager != nil {
				p.intelRdtManager.Destroy()
			}
		}
	}()
	if err := p.createNetworkInterfaces(); err != nil { // 创建网络接口
		return newSystemErrorWithCause(err, "creating network interfaces")
	}
	if err := p.sendConfig(); err != nil { // 把配置发送给子进程
		return newSystemErrorWithCause(err, "sending config to init process")
	}
	var (
		sentRun    bool
		sentResume bool
	)

	ierr := parseSync(p.messageSockPair.parent, func(sync *syncT) error {
		switch sync.Type {
		case procReady:
			// set rlimits, this has to be done here because we lose permissions
			// to raise the limits once we enter a user-namespace
			if err := setupRlimits(p.config.Rlimits, p.pid()); err != nil {
				return newSystemErrorWithCause(err, "setting rlimits for ready process")
			}
			// call prestart hooks
			if !p.config.Config.Namespaces.Contains(configs.NEWNS) {
				// Setup cgroup before prestart hook, so that the prestart hook could apply cgroup permissions.
				if err := p.manager.Set(p.config.Config); err != nil {
					return newSystemErrorWithCause(err, "setting cgroup config for ready process")
				}
				if p.intelRdtManager != nil {
					if err := p.intelRdtManager.Set(p.config.Config); err != nil {
						return newSystemErrorWithCause(err, "setting Intel RDT config for ready process")
					}
				}

				if p.config.Config.Hooks != nil {
					s, err := p.container.currentOCIState()
					if err != nil {
						return err
					}
					// initProcessStartTime hasn't been set yet.
					s.Pid = p.cmd.Process.Pid
					s.Status = "creating"
					for i, hook := range p.config.Config.Hooks.Prestart {
						if err := hook.Run(s); err != nil {
							return newSystemErrorWithCausef(err, "running prestart hook %d", i)
						}
					}
				}
			}
			// Sync with child.
			if err := writeSync(p.messageSockPair.parent, procRun); err != nil {
				return newSystemErrorWithCause(err, "writing syncT 'run'")
			}
			sentRun = true
		case procHooks:
			// Setup cgroup before prestart hook, so that the prestart hook could apply cgroup permissions.
			if err := p.manager.Set(p.config.Config); err != nil {
				return newSystemErrorWithCause(err, "setting cgroup config for procHooks process")
			}
			if p.intelRdtManager != nil {
				if err := p.intelRdtManager.Set(p.config.Config); err != nil {
					return newSystemErrorWithCause(err, "setting Intel RDT config for procHooks process")
				}
			}
			if p.config.Config.Hooks != nil {
				s, err := p.container.currentOCIState()
				if err != nil {
					return err
				}
				// initProcessStartTime hasn't been set yet.
				s.Pid = p.cmd.Process.Pid
				s.Status = "creating"
				for i, hook := range p.config.Config.Hooks.Prestart {
					if err := hook.Run(s); err != nil {
						return newSystemErrorWithCausef(err, "running prestart hook %d", i)
					}
				}
			}
			// Sync with child.
			if err := writeSync(p.messageSockPair.parent, procResume); err != nil {
				return newSystemErrorWithCause(err, "writing syncT 'resume'")
			}
			sentResume = true
		default:
			return newSystemError(fmt.Errorf("invalid JSON payload from child"))
		}

		return nil
	})

	if !sentRun {
		return newSystemErrorWithCause(ierr, "container init")
	}
	if p.config.Config.Namespaces.Contains(configs.NEWNS) && !sentResume {
		return newSystemError(fmt.Errorf("could not synchronise after executing prestart hooks with container process"))
	}
	if err := unix.Shutdown(int(p.messageSockPair.parent.Fd()), unix.SHUT_WR); err != nil {
		return newSystemErrorWithCause(err, "shutting down init pipe")
	}

	// Must be done after Shutdown so the child will exit and we can wait for it.
	if ierr != nil {
		p.wait()
		return ierr
	}
	return nil
}
````

运行到这里也就是 `runc create` 要返回了，但是子进程的 `runc init` 因为父进程的退出被 `1` 号进程接管。

## runc init

这个就是 `contianer` 启动的时候`swap`前的进程

```go
// StartInitialization loads a container by opening the pipe fd from the parent to read the configuration and state
// This is a low level implementation detail of the reexec and should not be consumed externally
func (l *LinuxFactory) StartInitialization() (err error) {
	var (
		pipefd, fifofd int
		consoleSocket  *os.File
		envInitPipe    = os.Getenv("_LIBCONTAINER_INITPIPE")
		envFifoFd      = os.Getenv("_LIBCONTAINER_FIFOFD")
		envConsole     = os.Getenv("_LIBCONTAINER_CONSOLE")
	)

	// Get the INITPIPE.
	pipefd, err = strconv.Atoi(envInitPipe)
	if err != nil {
		return fmt.Errorf("unable to convert _LIBCONTAINER_INITPIPE=%s to int: %s", envInitPipe, err)
	}

	var (
		pipe = os.NewFile(uintptr(pipefd), "pipe")
		it   = initType(os.Getenv("_LIBCONTAINER_INITTYPE"))
	)
	defer pipe.Close()

	// Only init processes have FIFOFD.
	fifofd = -1
	if it == initStandard {
		if fifofd, err = strconv.Atoi(envFifoFd); err != nil {
			return fmt.Errorf("unable to convert _LIBCONTAINER_FIFOFD=%s to int: %s", envFifoFd, err)
		}
	}

	if envConsole != "" {
		console, err := strconv.Atoi(envConsole)
		if err != nil {
			return fmt.Errorf("unable to convert _LIBCONTAINER_CONSOLE=%s to int: %s", envConsole, err)
		}
		consoleSocket = os.NewFile(uintptr(console), "console-socket")
		defer consoleSocket.Close()
	}

	// clear the current process's environment to clean any libcontainer
	// specific env vars.
	os.Clearenv()

	defer func() {
		// We have an error during the initialization of the container's init,
		// send it back to the parent process in the form of an initError.
		if werr := utils.WriteJSON(pipe, syncT{procError}); werr != nil {
			fmt.Fprintln(os.Stderr, err)
			return
		}
		if werr := utils.WriteJSON(pipe, newSystemError(err)); werr != nil {
			fmt.Fprintln(os.Stderr, err)
			return
		}
	}()
	defer func() {
		if e := recover(); e != nil {
			err = fmt.Errorf("panic from initialization: %v, %v", e, string(debug.Stack()))
		}
	}()

	i, err := newContainerInit(it, pipe, consoleSocket, fifofd)
	if err != nil {
		return err
	}

	// If Init succeeds, syscall.Exec will not return, hence none of the defers will be called.
	return i.Init()
}
```

`newContainerInit()`整体逻辑也比较简单

```go
func newContainerInit(t initType, pipe *os.File, consoleSocket *os.File, fifoFd int) (initer, error) {
	var config *initConfig
	if err := json.NewDecoder(pipe).Decode(&config); err != nil {
		return nil, err
	}
	if err := populateProcessEnvironment(config.Env); err != nil {
		return nil, err
	}
	switch t {
	case initSetns:
		return &linuxSetnsInit{
			pipe:          pipe,
			consoleSocket: consoleSocket,
			config:        config,
		}, nil
	case initStandard:
		return &linuxStandardInit{
			pipe:          pipe,
			consoleSocket: consoleSocket,
			parentPid:     unix.Getppid(),
			config:        config,
			fifoFd:        fifoFd,
		}, nil
	}
	return nil, fmt.Errorf("unknown init type %q", t)
}
```

当你运行 `runc crate` 这个时候的 `init` 是调用就是 `linuxStandardInit`

```go
func (l *linuxStandardInit) Init() error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
....	

	if err := setupNetwork(l.config); err != nil { // 根据 config 使用 netlink 进行配置
		return err
	}
	if err := setupRoute(l.config.Config); err != nil { // 使用 netlink 设置 route 
		return err
	}

	label.Init()
  // 下面这个注释特意 copy 过来的
  // prepareRootfs sets up the devices, mount points, and filesystems for use
  // inside a new mount namespace. It doesn't set anything as ro. You must call
  // finalizeRootfs after this function to finish setting up the rootfs.  
	if err := prepareRootfs(l.pipe, l.config); err != nil {
		return err
	}
	// Set up the console. This has to be done *before* we finalize the rootfs,
	// but *after* we've given the user the chance to set up all of the mounts
	// they wanted.
	if l.config.CreateConsole {
		if err := setupConsole(l.consoleSocket, l.config, true); err != nil {
			return err
		}
		if err := system.Setctty(); err != nil {
			return errors.Wrap(err, "setctty")
		}
	}

	// Finish the rootfs setup.
	if l.config.Config.Namespaces.Contains(configs.NEWNS) {
		if err := finalizeRootfs(l.config.Config); err != nil {
			return err
		}
	}

	if hostname := l.config.Config.Hostname; hostname != "" {
		if err := unix.Sethostname([]byte(hostname)); err != nil {
			return errors.Wrap(err, "sethostname")
		}
	}
	if err := apparmor.ApplyProfile(l.config.AppArmorProfile); err != nil {
		return errors.Wrap(err, "apply apparmor profile")
	}

	for key, value := range l.config.Config.Sysctl {
		if err := writeSystemProperty(key, value); err != nil {
			return errors.Wrapf(err, "write sysctl key %s", key)
		}
	}
	for _, path := range l.config.Config.ReadonlyPaths {
		if err := readonlyPath(path); err != nil {
			return errors.Wrapf(err, "readonly path %s", path)
		}
	}
	for _, path := range l.config.Config.MaskPaths {
		if err := maskPath(path, l.config.Config.MountLabel); err != nil {
			return errors.Wrapf(err, "mask path %s", path)
		}
	}
	pdeath, err := system.GetParentDeathSignal()
	if err != nil {
		return errors.Wrap(err, "get pdeath signal")
	}
	if l.config.NoNewPrivileges {
		if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
			return errors.Wrap(err, "set nonewprivileges")
		}
	}
	// Tell our parent that we're ready to Execv. This must be done before the
	// Seccomp rules have been applied, because we need to be able to read and
	// write to a socket.
	if err := syncParentReady(l.pipe); err != nil {
		return errors.Wrap(err, "sync ready")
	}
	if err := label.SetProcessLabel(l.config.ProcessLabel); err != nil {
		return errors.Wrap(err, "set process label")
	}
	defer label.SetProcessLabel("")
	// Without NoNewPrivileges seccomp is a privileged operation, so we need to
	// do this before dropping capabilities; otherwise do it as late as possible
	// just before execve so as few syscalls take place after it as possible.
	if l.config.Config.Seccomp != nil && !l.config.NoNewPrivileges {
		if err := seccomp.InitSeccomp(l.config.Config.Seccomp); err != nil {
			return err
		}
	}
	if err := finalizeNamespace(l.config); err != nil {
		return err
	}
	// finalizeNamespace can change user/group which clears the parent death
	// signal, so we restore it here.
	if err := pdeath.Restore(); err != nil {
		return errors.Wrap(err, "restore pdeath signal")
	}
	// Compare the parent from the initial start of the init process and make
	// sure that it did not change.  if the parent changes that means it died
	// and we were reparented to something else so we should just kill ourself
	// and not cause problems for someone else.
	if unix.Getppid() != l.parentPid {
		return unix.Kill(unix.Getpid(), unix.SIGKILL)
	}
	// Check for the arg before waiting to make sure it exists and it is
	// returned as a create time error.
	name, err := exec.LookPath(l.config.Args[0])
	if err != nil {
		return err
	}
	// Close the pipe to signal that we have completed our init.
	l.pipe.Close()
	// Wait for the FIFO to be opened on the other side before exec-ing the
	// user process. We open it through /proc/self/fd/$fd, because the fd that
	// was given to us was an O_PATH fd to the fifo itself. Linux allows us to
	// re-open an O_PATH fd through /proc.
  // 看一下注释，这里利用了 fifo 的特点，等待 runc start 来开这个 fifo
	fd, err := unix.Open(fmt.Sprintf("/proc/self/fd/%d", l.fifoFd), unix.O_WRONLY|unix.O_CLOEXEC, 0) // 一起准备就绪过后他就会 hang 在这里
	if err != nil {
		return newSystemErrorWithCause(err, "open exec fifo")
	}
	if _, err := unix.Write(fd, []byte("0")); err != nil { // 当用户调用 runc start 打开 fifo ，就会执行到这里
		return newSystemErrorWithCause(err, "write 0 exec fifo")
	}
	// Close the O_PATH fifofd fd before exec because the kernel resets
	// dumpable in the wrong order. This has been fixed in newer kernels, but
	// we keep this to ensure CVE-2016-9962 doesn't re-emerge on older kernels.
	// N.B. the core issue itself (passing dirfds to the host filesystem) has
	// since been resolved.
	// https://github.com/torvalds/linux/blob/v4.9/fs/exec.c#L1290-L1318
	unix.Close(l.fifoFd)
	// Set seccomp as close to execve as possible, so as few syscalls take
	// place afterward (reducing the amount of syscalls that users need to
	// enable in their seccomp profiles).
	if l.config.Config.Seccomp != nil && l.config.NoNewPrivileges {
		if err := seccomp.InitSeccomp(l.config.Config.Seccomp); err != nil {
			return newSystemErrorWithCause(err, "init seccomp")
		}
	}
	if err := syscall.Exec(name, l.config.Args[0:], os.Environ()); err != nil { // 这里 swap 用户的进程了
		return newSystemErrorWithCause(err, "exec user process")
	}
	return nil
}

```

## runc start 

其实 `runc start` 的逻辑更简单，仅仅是通过 `fifo` 和 `runc init`进程沟通，让他继续执行用户进程。

```go
var startCommand = cli.Command{
	Name:  "start",
...
		container, err := getContainer(context)
		if err != nil {
			return err
		}
		status, err := container.Status()
		if err != nil {
			return err
		}
		switch status {
		case libcontainer.Created:
			return container.Exec()
```

```go
func (c *linuxContainer) Exec() error {
	c.m.Lock()
	defer c.m.Unlock()
	return c.exec()
}
```

打开子进程的`fifo.exec` 文件，子进程就能继续执行下去了。

```go
func (c *linuxContainer) exec() error {
	path := filepath.Join(c.root, execFifoFilename)
	pid := c.initProcess.pid()
	blockingFifoOpenCh := awaitFifoOpen(path)
	for {
		select {
		case result := <-blockingFifoOpenCh:
			return handleFifoResult(result)

		case <-time.After(time.Millisecond * 100):
			stat, err := system.Stat(pid)
			if err != nil || stat.State == system.Zombie {
				// could be because process started, ran, and completed between our 100ms timeout and our system.Stat() check.
				// see if the fifo exists and has data (with a non-blocking open, which will succeed if the writing process is complete).
				if err := handleFifoResult(fifoOpen(path, false)); err != nil {
					return errors.New("container process is already dead")
				}
				return nil
			}
		}
	}
}
```

```go
func handleFifoResult(result openResult) error {
	if result.err != nil {
		return result.err
	}
	f := result.file
	defer f.Close()
	if err := readFromExecFifo(f); err != nil { //
		return err
	}
	return os.Remove(f.Name())
}
```

```go
func readFromExecFifo(execFifo io.Reader) error {
	data, err := ioutil.ReadAll(execFifo)
	if err != nil {
		return err
	}
	if len(data) <= 0 {
		return fmt.Errorf("cannot start an already running container")
	}
	return nil
}
```

打开 `fifo`，如果 `data` 小于 0 说明这个  `fifo` 里面 0 已经被读完了，也就是 running 的。

