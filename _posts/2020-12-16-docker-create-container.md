---
author: sn0rt
comments: true
date: 2020-12-16
layout: post
title: dockershim 与 dockerd
tag: k8s
---

在`kubelet`的 `dockershim` 的代码中看以下代码，知道了调用了`docker` 的 `create` 与 `start`.

```go
func (ds *dockerService) RunPodSandbox(ctx context.Context, r *runtimeapi.RunPodSandboxRequest) (*runtimeapi.RunPodSandboxResponse, error) {
	config := r.GetConfig()
...
	createConfig, err := ds.makeSandboxDockerConfig(config, image)
	if err != nil {
		return nil, fmt.Errorf("failed to make sandbox docker config for pod %q: %v", config.Metadata.Name, err)
	}
	createResp, err := ds.client.CreateContainer(*createConfig) // 这里的创建 sandbox 是备好 container 需要底层资源
...
	// Step 4: Start the sandbox container.
	// Assume kubelet's garbage collector would remove the sandbox later, if
	// startContainer failed.
	err = ds.client.StartContainer(createResp.ID) // 前面准备好 container 这里才去启动，具体怎么启动 kubelet 并不关心
	if err != nil {
		return nil, fmt.Errorf("failed to start sandbox container for pod %q: %v", config.Metadata.Name, err)
	}
```
上面还是 `dockershim` 的代码可以发现`ds.client.CreateContainer(*createConfig)`和`ds.client.StartContainer(createResp.ID)`。这次主要关注`ds.client.StartContainer()`，是因为`CreateContainer`的逻辑比较简单。

```go
	resp, err := cli.post(ctx, "/containers/"+containerID+"/start", query, nil, nil)
```

通过对代码的分析发现`StartContainer`最后发出的是 `http` 请求。

##  dockerd 的 `/containers/{name:.*}/start`接口

基于前面的分析我已经知道 `kubelet` 的 `dockershim` 其实使用调用的 `docker` 的 `resftul api`，根据线上 docker 的版本信息 `18.09.9` `checkout`相对应的代码。可以发现 `container`流程相关的逻辑在`docker/api/server/router/container/container.go`的`initRoutes() `中。

```go
		router.NewPostRoute("/containers/{name:.*}/start", r.postContainersStart),
```

上面是 handler 主要逻辑很简单，下面就是启动 `container` 的核心流程了。

```go
func (s *containerRouter) postContainersStart(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error {
	// If contentLength is -1, we can assumed chunked encoding
	// or more technically that the length is unknown
	// https://golang.org/src/pkg/net/http/request.go#L139
	// net/http otherwise seems to swallow any headers related to chunked encoding
	// including r.TransferEncoding
	// allow a nil body for backwards compatibility

	// 移除 http 检查相关逻辑，哪些不影响核心
	if err := s.backend.ContainerStart(vars["name"], hostConfig, checkpoint, checkpointDir); err != nil { // here 
...
```

```go
// ContainerStart starts a container.
func (daemon *Daemon) ContainerStart(name string, hostConfig *containertypes.HostConfig, checkpoint string, checkpointDir string) error {
// 删除大量的保护式编程非核心逻辑代码
	return daemon.containerStart(container, checkpoint, checkpointDir, true) // here
}
```

跟如这个`Start`函数发现居然是使用 `grpc `去调用`/containerd.services.tasks.v1.Tasks/Start`的接口。

```go
// containerStart prepares the container to run by setting up everything the
// container needs, such as storage and networking, as well as links
// between containers. The container is left waiting for a signal to
// begin running.
func (daemon *Daemon) containerStart(container *container.Container, checkpoint string, checkpointDir string, resetRestartManager bool) (err error) {
	start := time.Now()
	container.Lock()
	defer container.Unlock()
	// 删除错误处理与一下防御编程

	if err := daemon.conditionalMountOnStart(container); err != nil {
		return err
	}

	if err := daemon.initializeNetworking(container); err != nil {
		return err
	}

	spec, err := daemon.createSpec(container)
	if err != nil {
		return errdefs.System(err)
	}

// 删除一下非核心功能代码

	createOptions, err := daemon.getLibcontainerdCreateOptions(container)
	if err != nil {
		return err
	}

	ctx := context.TODO()

	err = daemon.containerd.Create(ctx, container.ID, spec, createOptions) // 这里最终会调用 cotnainerd 的 create
	// 删除错误处理相关代码
	// TODO(mlaventure): we need to specify checkpoint options here
	pid, err := daemon.containerd.Start(context.Background(), container.ID, checkpointDir, // 这里需要跟进一下
		container.StreamConfig.Stdin() != nil || container.Config.Tty,
		container.InitializeStdio)
  // 忽略错误处理
...
```

`containerStart` 函数准备 `containerd` 运行的一切需要的东西包括存储和网络。但是实际启动可以发现是调用了`daemon.containerd.Create`与`daemon.containerd.Start`接口，细节下面进一步分析。

## client.create 方法实现

前面看到 `dockerd` 的 `start` 接口，会调用他的 ``daemon.containerd.Create`

```go
func (c *client) Create(ctx context.Context, id string, ociSpec *specs.Spec, runtimeOptions interface{}) error {
	if ctr := c.getContainer(id); ctr != nil {
		return errors.WithStack(newConflictError("id already in use"))
	}

	bdir, err := prepareBundleDir(filepath.Join(c.stateDir, id), ociSpec) // 其实就是准备容器启动目录之类的
	if err != nil {
		return errdefs.System(errors.Wrap(err, "prepare bundle dir failed"))
	}

	c.logger.WithField("bundle", bdir).WithField("root", ociSpec.Root.Path).Debug("bundle dir created")

	cdCtr, err := c.client.NewContainer(ctx, id, // 核心代码，更多的逻辑需要下面展开
		containerd.WithSpec(ociSpec),
		// TODO(mlaventure): when containerd support lcow, revisit runtime value
		containerd.WithRuntime(fmt.Sprintf("io.containerd.runtime.v1.%s", runtime.GOOS), runtimeOptions))
	if err != nil {
		return wrapError(err)
	}

	c.Lock()
	c.containers[id] = &container{
		bundleDir: bdir,
		ctr:       cdCtr,
	}
	c.Unlock()

	return nil
}
```

`NewContainer()` 就是这一段代码的核心，需要展开说明

```go
// NewContainer will create a new container in container with the provided id
// the id must be unique within the namespace
func (c *Client) NewContainer(ctx context.Context, id string, opts ...NewContainerOpts) (Container, error) {
   ctx, done, err := c.WithLease(ctx)
   if err != nil {
      return nil, err
   }
   defer done(ctx)

   container := containers.Container{
      ID: id,
      Runtime: containers.RuntimeInfo{
         Name: c.runtime,
      },
   }
   for _, o := range opts {
      if err := o(ctx, c, &container); err != nil {
         return nil, err
      }
   }
   r, err := c.ContainerService().Create(ctx, container) // 核心就是 create 了
   if err != nil {
      return nil, err
   }
   return containerFromRecord(c, r), nil
}
```

可以看到`c.ContainerService().Create(ctx, container)`其实调用了 `container service`，这个个是 `docker` 层面的抽象，具体实现是 `containerd`提供的。

```go
func (r *remoteContainers) Create(ctx context.Context, container containers.Container) (containers.Container, error) {
   created, err := r.client.Create(ctx, &containersapi.CreateContainerRequest{
      Container: containerToProto(&container),
...
```

```go
func (c *containersClient) Create(ctx context.Context, in *CreateContainerRequest, opts ...grpc.CallOption) (*CreateContainerResponse, error) {
	out := new(CreateContainerResponse)
	err := grpc.Invoke(ctx, "/containerd.services.containers.v1.Containers/Create", in, out, c.cc, opts...)
...
```

基于上述`client.create`其实也可以发现，实质性的工作只有一个就是准备启动需要一些目录结构。这一切都是为了准备调用 `/containerd.services.containers.v1.Containers/Create`接口。

##  client.Start

`docker` 调用完成 `containerd` 的 `create` 下面就要调用 `daemon.containerd.Start()`。

```go
// Start create and start a task for the specified containerd id
func (c *client) Start(ctx context.Context, id, checkpointDir string, withStdin bool, attachStdio StdioCallback) (int, error) {
	ctr := c.getContainer(id)
	if ctr == nil {
		return -1, errors.WithStack(newNotFoundError("no such container"))
	}
	if t := ctr.getTask(); t != nil {
		return -1, errors.WithStack(newConflictError("container already started"))
	}

	var (
		cp             *types.Descriptor
		t              containerd.Task
		rio            cio.IO
		err            error
		stdinCloseSync = make(chan struct{})
	)

	// 忽略 checkpoint 相关代码

	spec, err := ctr.ctr.Spec(ctx)
	if err != nil {
		return -1, errors.Wrap(err, "failed to retrieve spec")
	}
	uid, gid := getSpecUser(spec)
	t, err = ctr.ctr.NewTask(ctx, // 这里就是调用 containerd, /containerd.services.tasks.v1.Tasks/Create
		func(id string) (cio.IO, error) {
			fifos := newFIFOSet(ctr.bundleDir, InitProcessName, withStdin, spec.Process.Terminal)

			rio, err = c.createIO(fifos, id, InitProcessName, stdinCloseSync, attachStdio)
			return rio, err
		},
		func(_ context.Context, _ *containerd.Client, info *containerd.TaskInfo) error {
			info.Checkpoint = cp
			info.Options = &runctypes.CreateOptions{
				IoUid:       uint32(uid),
				IoGid:       uint32(gid),
				NoPivotRoot: os.Getenv("DOCKER_RAMDISK") != "",
			}
			return nil
		})
// 移除错误处理相关代码
	ctr.setTask(t)

	// Signal c.createIO that it can call CloseIO
	close(stdinCloseSync)

	if err := t.Start(ctx); err != nil { // 这个t是task的缩写, /containerd.services.tasks.v1.Tasks/Start
// 移除错误处理相关代码
```

基于上述代码可以看到，这里还是二次封装了。

`ctr.ctr.NewTask` 就是准备好参数准备调用 `containerd`的`/containerd.services.tasks.v1.Tasks/Create`接口。

```go
func (c *container) NewTask(ctx context.Context, ioCreate cio.Creator, opts ...NewTaskOpts) (_ Task, err error) {
  // 删除析构函数和错误处理
	cfg := i.Config()
	request := &tasks.CreateTaskRequest{
		ContainerID: c.id,
		Terminal:    cfg.Terminal,
		Stdin:       cfg.Stdin,
		Stdout:      cfg.Stdout,
		Stderr:      cfg.Stderr,
	}
	// 删除部分代码
	response, err := c.client.TaskService().Create(ctx, request) // task service create
	if err != nil {
		return nil, errdefs.FromGRPC(err)
	}
	t.pid = response.Pid
	return t, nil
}
```

```go
func (c *tasksClient) Create(ctx context.Context, in *CreateTaskRequest, opts ...grpc.CallOption) (*CreateTaskResponse, error) {
   out := new(CreateTaskResponse)
   err := grpc.Invoke(ctx, "/containerd.services.tasks.v1.Tasks/Create", in, out, c.cc, opts...)
   if err != nil {
      return nil, err
   }
   return out, nil
}
```

而`t.Start(ctx)`函数的实现更简单，最后调用`containerd`的`/containerd.services.tasks.v1.Tasks/Start`接口

```go
func (c *tasksClient) Start(ctx context.Context, in *StartRequest, opts ...grpc.CallOption) (*StartResponse, error) {
	out := new(StartResponse)
	err := grpc.Invoke(ctx, "/containerd.services.tasks.v1.Tasks/Start", in, out, c.cc, opts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}
```

基于以上分析，其实 `dockerd` 的`ContainerStart`先后会调用到`cotnainerd`的`/containerd.services.containers.v1.Containers/Create`，其次`/containerd.services.tasks.v1.Tasks/Create`，最后是`/containerd.services.tasks.v1.Tasks/Start`。

那么下面就去走读一下 `containerd`的相关实现。