---
author: sn0rt
comments: true
date: 2020-12-18
layout: post
title: containerd 与 containerd-shim
tag: k8s
---

根据线上信息 `checkout `出`containerd`版本为`7ad184331fa3e55e52b890ea95e65ba581ae3429`的代码进行走读。根据上一篇结束的接口信息，直接搜索相关`GRPC`接口可以找到实现的 `handler`。

```go
func _Containers_Create_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor 
...
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: "/containerd.services.containers.v1.Containers/Create",
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(ContainersServer).Create(ctx, req.(*CreateContainerRequest))
...    
```

```go
func _Tasks_Create_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
...
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: "/containerd.services.tasks.v1.Tasks/Create",
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(TasksServer).Create(ctx, req.(*CreateTaskRequest))
...
```

```go
func _Tasks_Start_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
...
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: "/containerd.services.tasks.v1.Tasks/Start",
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(TasksServer).Start(ctx, req.(*StartRequest))
...
```

那么这一篇分别走读一下三个接口是如何实现的。

## ContainersServer.Create 方法的实现

再来看一下`create`实现，通过之前 api 配合 IDE 就能直接转跳到下面的代码实现。

```go
func (l *local) Create(ctx context.Context, req *api.CreateContainerRequest, _ ...grpc.CallOption) (*api.CreateContainerResponse, error) {
	var resp api.CreateContainerResponse

	if err := l.withStoreUpdate(ctx, func(ctx context.Context, store containers.Store) error {
		container := containerFromProto(&req.Container)

		created, err := store.Create(ctx, container) // 将container的信息写入本地的一个数据库
...
```
通过对上面代码走读分析，发现其实 `cotnainerd` 的 `create` 操作仅仅就是写一个数据到 `bucket ` 中去，还有一个 `event`信息 `create container`。目前还不明白这个 `event` 除了使用 `ctr events`看到还有其他的作用么？

## TasksServer.Create 方法的实现

`containerd` 使用 `task` 来管理 `container` 的创建和删除，在 `containerd` 的 `readme` 文档中也写的比较清楚了。

```go
func (l *local) Create(ctx context.Context, r *api.CreateTaskRequest, _ ...grpc.CallOption) (*api.CreateTaskResponse, error) {
	var (
		checkpointPath string
		err            error
	)

	container, err := l.getContainer(ctx, r.ContainerID) // 前面写 db，这里读 db 获取 cotnainer 的信息。
	if err != nil {
		return nil, errdefs.ToGRPC(err)
	}
	opts := runtime.CreateOpts{
		Spec: container.Spec,
		IO: runtime.IO{
			Stdin:    r.Stdin,
			Stdout:   r.Stdout,
			Stderr:   r.Stderr,
			Terminal: r.Terminal,
		},
		Checkpoint:     checkpointPath,
		Runtime:        container.Runtime.Name,
		RuntimeOptions: container.Runtime.Options,
		TaskOptions:    r.Options,
	}
	for _, m := range r.Rootfs {
		opts.Rootfs = append(opts.Rootfs, mount.Mount{
			Type:    m.Type,
			Source:  m.Source,
			Options: m.Options,
		})
	}
	runtime, err := l.getRuntime(container.Runtime.Name) // runtime 名字，现在有 v1.linux, v2 两个实现
	if err != nil {
		return nil, err
	}
	c, err := runtime.Create(ctx, r.ContainerID, opts) // 目前线上使用 v1 （目前是通过 containerd-shim 后面的参数判断出来的，v1/v2 参数差别很明显
	if err != nil {
		return nil, errdefs.ToGRPC(err)
	}
	// TODO: fast path for getting pid on create
	if err := l.monitor.Monitor(c); err != nil {
		return nil, errors.Wrap(err, "monitor task")
	}
	state, err := c.State(ctx)
	if err != nil {
		log.G(ctx).Error(err)
	}
	return &api.CreateTaskResponse{
		ContainerID: r.ContainerID,
		Pid:         state.Pid,
	}, nil
}
```

这里使用 `v1 Linux runtime` 的`create` 方法

```go
// Create a new task
func (r *Runtime) Create(ctx context.Context, id string, opts runtime.CreateOpts) (_ runtime.Task, err error) {
	namespace, err := namespaces.NamespaceRequired(ctx) // 这里 ns 是 moby，就是 docker 那个新的名字
	if err != nil {
		return nil, err
	}

	if err := identifiers.Validate(id); err != nil {
		return nil, errors.Wrapf(err, "invalid task id")
	}

	ropts, err := r.getRuncOptions(ctx, id)
	if err != nil {
		return nil, err
	}

	bundle, err := newBundle(id, // newBundle creates a new bundle on disk at the provided path for the given id
		filepath.Join(r.state, namespace),
		filepath.Join(r.root, namespace),
		opts.Spec.Value)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			bundle.Delete()
		}
	}()

  // ShimLocal is a ShimOpt for using an in process shim implementation
	shimopt := ShimLocal(r.config, r.events)
	if !r.config.NoShim { // 在正常的逻辑会命中这里，我们使用了 shim
		var cgroup string
		if opts.TaskOptions != nil {
			v, err := typeurl.UnmarshalAny(opts.TaskOptions)
			if err != nil {
				return nil, err
			}
			cgroup = v.(*runctypes.CreateOptions).ShimCgroup
		}
		exitHandler := func() {
			log.G(ctx).WithField("id", id).Info("shim reaped")
			t, err := r.tasks.Get(ctx, id)
			if err != nil {
				// Task was never started or was already successfully deleted
				return
			}
			lc := t.(*Task)

			log.G(ctx).WithFields(logrus.Fields{
				"id":        id,
				"namespace": namespace,
			}).Warn("cleaning up after killed shim")
			if err = r.cleanupAfterDeadShim(context.Background(), bundle, namespace, id, lc.pid); err != nil {
				log.G(ctx).WithError(err).WithFields(logrus.Fields{
					"id":        id,
					"namespace": namespace,
				}).Warn("failed to clean up after killed shim")
			}
		}   
		shimopt = ShimRemote(r.config, r.address, cgroup, exitHandler) 
    // 这里目前只是构建好了 shimopt 这个函数，目前还没有真的调用
	}

	// shimopt 这个函数准备好了，这里才开始调用启动 shim 并返回 shim client
	s, err := bundle.NewShimClient(ctx, namespace, shimopt, ropts) 
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			if kerr := s.KillShim(ctx); kerr != nil {
				log.G(ctx).WithError(err).Error("failed to kill shim")
			}
		}
	}()

	rt := r.config.Runtime
	if ropts != nil && ropts.Runtime != "" {
		rt = ropts.Runtime
	}
	sopts := &shim.CreateTaskRequest{
		ID:         id,
		Bundle:     bundle.path,
		Runtime:    rt,
		Stdin:      opts.IO.Stdin,
		Stdout:     opts.IO.Stdout,
		Stderr:     opts.IO.Stderr,
		Terminal:   opts.IO.Terminal,
		Checkpoint: opts.Checkpoint,
		Options:    opts.TaskOptions,
	}
	for _, m := range opts.Rootfs {
		sopts.Rootfs = append(sopts.Rootfs, &types.Mount{
			Type:    m.Type,
			Source:  m.Source,
			Options: m.Options,
		})
	}
	// Create a new initial process and container with the underlying OCI runtime 
  // 
	cr, err := s.Create(ctx, sopts) // 也就是 shim 的 create 方法，按住不表到讲 containerd-shim 再说。
	if err != nil {
		return nil, errdefs.FromGRPC(err)
	}
	t, err := newTask(id, namespace, int(cr.Pid), s, r.events, r.tasks, bundle)
	if err != nil {
		return nil, err
	}
	if err := r.tasks.Add(ctx, t); err != nil {
		return nil, err
	}
	// ... 移除一部分 event 相关逻辑
	return t, nil
}
```



基于以上其实就已经准备好了 `task` 并启动 ，在 `cotnainerd` 中调用使用命令行调用 `containerd-shim`。其余的逻辑要到 `cotnainerd-shim` 中去探索了。

##  tasks.v1.Tasks/Start 方法的实现

`create` 操作看完了看一下 `start` 方法是如何实现的，搜索其对应的接口 `/containerd.services.tasks.v1.Tasks/Start`


```go
func (s *service) Start(ctx context.Context, r *api.StartRequest) (*api.StartResponse, error) {
	return s.local.Start(ctx, r)
```

依然是 `v1.linux` 实现

```go
func (l *local) Start(ctx context.Context, r *api.StartRequest, _ ...grpc.CallOption) (*api.StartResponse, error) {
	t, err := l.getTask(ctx, r.ContainerID) // 这里就是从 bucket db 中获取数据
	if err != nil {
		return nil, err
	}
	p := runtime.Process(t)
	if r.ExecID != "" {
		if p, err = t.Process(ctx, r.ExecID); err != nil {
			return nil, errdefs.ToGRPC(err)
		}
	}
	if err := p.Start(ctx); err != nil { // Start the container's user defined process
		return nil, errdefs.ToGRPC(err)
	}
	state, err := p.State(ctx)
	if err != nil {
		return nil, errdefs.ToGRPC(err) // ToGRPC
	}
	return &api.StartResponse{
		Pid: state.Pid,
	}, nil
...
```

```go
// Start the task
func (t *Task) Start(ctx context.Context) error {
	t.mu.Lock()
	hasCgroup := t.cg != nil
	t.mu.Unlock()
	r, err := t.shim.Start(ctx, &shim.StartRequest{ // 调用 shim 的 start
		ID: t.id,
...
```

基于以上两个接口其实发现更多工作 `containerd` 放到了 `conteinrd-shim` 中完成了。

## containerd-shim 的如何工作

初看 `containerd-shim` 的实现模型也不是很复杂，主函数中调用一个 `rpc` 服务常驻后台，对外提供服务。

```go
func main() {
...

	if err := executeShim(); err != nil {
```

```go
func executeShim() error {
....
	}
	server, err := newServer()
	if err != nil {
		return errors.Wrap(err, "failed creating server")
	}
	sv, err := shim.NewService(
		shim.Config{
			Path:          path,
			Namespace:     namespaceFlag,
			WorkDir:       workdirFlag,
			Criu:          criuFlag,
			SystemdCgroup: systemdCgroupFlag,
			RuntimeRoot:   runtimeRootFlag,
		},
		&remoteEventsPublisher{address: addressFlag},
	)
	if err != nil {
		return err
	}
	logrus.Debug("registering ttrpc server")
	shimapi.RegisterShimService(server, sv) // ttrpc 

	socket := socketFlag
	if err := serve(context.Background(), server, socket); err != nil {
		return err
	}
....
```

唯一值得一提的就是`ttrpc`是低内存下面的 rpc 协议，基于 grpc 的低内存版本。

```go
func RegisterShimService(srv *ttrpc.Server, svc ShimService) {
	srv.Register("containerd.runtime.linux.shim.v1.Shim", map[string]ttrpc.Method{
...
		"Create": func(ctx context.Context, unmarshal func(interface{}) error) (interface{}, error) {
			var req CreateTaskRequest
			if err := unmarshal(&req); err != nil {
				return nil, err
			}
			return svc.Create(ctx, &req)
		},
		"Start": func(ctx context.Context, unmarshal func(interface{}) error) (interface{}, error) {
			var req StartRequest
			if err := unmarshal(&req); err != nil {
				return nil, err
			}
			return svc.Start(ctx, &req)
		},
```

这次只关心 `shim` 的 `Create` 与 `Start` 实现。

## contained-shim create 的实现

这个就是`containerd`的`s.Create(ctx, sopts)`实现的地方

```go
func (c *local) Create(ctx context.Context, in *shimapi.CreateTaskRequest) (*shimapi.CreateTaskResponse, error) {
	return c.s.Create(ctx, in)
...
```

`create`

```go
// Create a new initial process and container with the underlying OCI runtime
func (s *Service) Create(ctx context.Context, r *shimapi.CreateTaskRequest) (_ *shimapi.CreateTaskResponse, err error) {
	var mounts []proc.Mount
	for _, m := range r.Rootfs {
		mounts = append(mounts, proc.Mount{
			Type:    m.Type,
			Source:  m.Source,
			Target:  m.Target,
			Options: m.Options,
		})
	}

	config := &proc.CreateConfig{
		ID:               r.ID,
		Bundle:           r.Bundle,
		Runtime:          r.Runtime,
		Rootfs:           mounts,
		Terminal:         r.Terminal,
		Stdin:            r.Stdin,
		Stdout:           r.Stdout,
		Stderr:           r.Stderr,
		Checkpoint:       r.Checkpoint,
		ParentCheckpoint: r.ParentCheckpoint,
		Options:          r.Options,
	}
	rootfs := filepath.Join(r.Bundle, "rootfs")
	defer func(rootfs string) {
		if err != nil {
			if err2 := mount.UnmountAll(rootfs, 0); err2 != nil {
				log.G(ctx).WithError(err2).Warn("Failed to cleanup rootfs mount")
			}
		}
	}(rootfs)
	for _, rm := range mounts {
		m := &mount.Mount{
			Type:    rm.Type,
			Source:  rm.Source,
			Options: rm.Options,
		}
		if err := m.Mount(rootfs); err != nil {
			return nil, errors.Wrapf(err, "failed to mount rootfs component %v", m)
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if len(mounts) == 0 {
		rootfs = ""
	}

	process, err := newInit(
		ctx,
		s.config.Path,
		s.config.WorkDir,
		s.config.RuntimeRoot,
		s.config.Namespace,
		s.config.Criu,
		s.config.SystemdCgroup,
		s.platform,
		config,
		rootfs,
	)
	if err != nil {
		return nil, errdefs.ToGRPC(err)
	}
	if err := process.Create(ctx, config); err != nil {
		return nil, errdefs.ToGRPC(err)
	}
	// save the main task id and bundle to the shim for additional requests
	s.id = r.ID
	s.bundle = r.Bundle
	pid := process.Pid()
	s.processes[r.ID] = process
	return &shimapi.CreateTaskResponse{
		Pid: uint32(pid),
	}, nil
}

```

```go
// Create the process with the provided config
func (p *Init) Create(ctx context.Context, r *CreateConfig) error {
	var (
		err    error
		socket *runc.Socket
	)

	if r.Terminal {
		if socket, err = runc.NewTempConsoleSocket(); err != nil {
			return errors.Wrap(err, "failed to create OCI runtime console socket")
		}
		defer socket.Close()
	} else if hasNoIO(r) {
		if p.io, err = runc.NewNullIO(); err != nil {
			return errors.Wrap(err, "creating new NULL IO")
		}
	} else {
		if p.io, err = runc.NewPipeIO(p.IoUID, p.IoGID, withConditionalIO(p.stdio)); err != nil {
			return errors.Wrap(err, "failed to create OCI runtime io pipes")
		}
	}
	pidFile := filepath.Join(p.Bundle, InitPidFile)
	if r.Checkpoint != "" {
		opts := &runc.RestoreOpts{
			CheckpointOpts: runc.CheckpointOpts{
				ImagePath:  r.Checkpoint,
				WorkDir:    p.WorkDir,
				ParentPath: r.ParentCheckpoint,
			},
			PidFile:     pidFile,
			IO:          p.io,
			NoPivot:     p.NoPivotRoot,
			Detach:      true,
			NoSubreaper: true,
		}
		p.initState = &createdCheckpointState{
			p:    p,
			opts: opts,
		}
		return nil
	}
	opts := &runc.CreateOpts{
		PidFile:      pidFile,
		IO:           p.io,
		NoPivot:      p.NoPivotRoot,
		NoNewKeyring: p.NoNewKeyring,
	}
	if socket != nil {
		opts.ConsoleSocket = socket
	}
	if err := p.runtime.Create(ctx, r.ID, r.Bundle, opts); err != nil {
		return p.runtimeError(err, "OCI runtime create failed")
	}
	if r.Stdin != "" {
		sc, err := fifo.OpenFifo(context.Background(), r.Stdin, syscall.O_WRONLY|syscall.O_NONBLOCK, 0)
		if err != nil {
			return errors.Wrapf(err, "failed to open stdin fifo %s", r.Stdin)
		}
		p.stdin = sc
		p.closers = append(p.closers, sc)
	}
	var copyWaitGroup sync.WaitGroup
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if socket != nil {
		console, err := socket.ReceiveMaster()
		if err != nil {
			return errors.Wrap(err, "failed to retrieve console master")
		}
		console, err = p.Platform.CopyConsole(ctx, console, r.Stdin, r.Stdout, r.Stderr, &p.wg, &copyWaitGroup)
		if err != nil {
			return errors.Wrap(err, "failed to start console copy")
		}
		p.console = console
	} else if !hasNoIO(r) {
		if err := copyPipes(ctx, p.io, r.Stdin, r.Stdout, r.Stderr, &p.wg, &copyWaitGroup); err != nil {
			return errors.Wrap(err, "failed to start io pipe copy")
		}
	}

	copyWaitGroup.Wait()
	pid, err := runc.ReadPidFile(pidFile)
	if err != nil {
		return errors.Wrap(err, "failed to retrieve OCI runtime container pid")
	}
	p.pid = pid
	return nil
}
```

```go
// Create creates a new container and returns its pid if it was created successfully
func (r *Runc) Create(context context.Context, id, bundle string, opts *CreateOpts) error {
	args := []string{"create", "--bundle", bundle} // 这里就是 runc create --bundle 的命令行了
	if opts != nil {
		oargs, err := opts.args()
		if err != nil {
			return err
		}
		args = append(args, oargs...)
	}
	cmd := r.command(context, append(args, id)...)
	if opts != nil && opts.IO != nil {
		opts.Set(cmd)
	}
	cmd.ExtraFiles = opts.ExtraFiles

	if cmd.Stdout == nil && cmd.Stderr == nil {
		data, err := cmdOutput(cmd, true)
		if err != nil {
			return fmt.Errorf("%s: %s", err, data)
		}
		return nil
	}
...
```

## contained-shim start 的实现

基于 containerd 的分析其实还看到调用 `t.shim.Start(ctx, &shim.StartRequest{ID: t.id})`

```go
func (c *local) Start(ctx context.Context, in *shimapi.StartRequest) (*shimapi.StartResponse, error) {
   return c.s.Start(ctx, in)  
```

```go
// Start a process
func (s *Service) Start(ctx context.Context, r *shimapi.StartRequest) (*shimapi.StartResponse, error) {
   p, err := s.getExecProcess(r.ID) // get exec process 
   if err != nil {
      return nil, err
   }
   if err := p.Start(ctx); err != nil {
      return nil, err
   }
   return &shimapi.StartResponse{
      ID:  p.ID(),
      Pid: uint32(p.Pid()),
   }, nil
```

```go
func (e *execProcess) Start(ctx context.Context) error {
   e.mu.Lock()
   defer e.mu.Unlock()

   return e.execState.Start(ctx) // execState 这会应该是 created，因为前面已经 runc create --bundle 了
```

```go
func (s *createdState) Start(ctx context.Context) error {
	if err := s.p.start(ctx); err != nil {
```

```go
func (p *Init) start(ctx context.Context) error {
	err := p.runtime.Start(ctx, p.id)
```

```go
// Start will start an already created container
func (r *Runc) Start(context context.Context, id string) error {
   return r.runOrError(r.command(context, "start", id)) // 这里会运行，r.command 返回的 exec.Cmd object 
}
```

```go
func (r *Runc) command(context context.Context, args ...string) *exec.Cmd {
   command := r.Command
   if command == "" {
      command = DefaultCommand // DefaultCommand = "runc"
   }
   cmd := exec.CommandContext(context, command, append(r.args(), args...)...)
   cmd.SysProcAttr = &syscall.SysProcAttr{
      Setpgid: r.Setpgid,
   }
   cmd.Env = filterEnv(os.Environ(), "NOTIFY_SOCKET") // NOTIFY_SOCKET introduces a special behavior in runc but should only be set if invoked from systemd
   if r.PdeathSignal != 0 {
      cmd.SysProcAttr.Pdeathsig = r.PdeathSignal
   }

   return cmd
}
```



那么其实到这里也就看完了 `containrd-shim` 调用 `runc create `/ `runc start `