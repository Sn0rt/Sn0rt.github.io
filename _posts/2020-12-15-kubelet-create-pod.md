---
author: sn0rt
comments: true
date: 2020-12-15
layout: post
title: kubelet 与 dockershim
tag: k8s
---

出于 containerd 上线需求，准备确定一下线上集群的的 pod 的创建过程。

# kubelet 启动日志分析

这次对 `kubelet` 分析主要关注 `1.17.4` 版本，其的 `kubelet` 初始化流程可以看到与运行时相关参数如下`--container-runtime=` 参数为 `docker`。查看启动日志，可以看到 `kubelet` 启动了一个 `dockershim` 的服务，这个服务就是目前调研的一个关键点，因为社区在 `1.20` 中准备弃用 `dockershim` 了。

```
I1215 16:38:23.359299 2052022 docker_service.go:274] Setting cgroupDriver to cgroupfs
I1215 16:38:23.359435 2052022 kubelet.go:642] Starting the GRPC server for the docker CRI shim.
I1215 16:38:23.359456 2052022 docker_server.go:59] Start dockershim grpc server
...
```

调研社区文档发现，`dockershim` 之所以被提出是为了解决`kubernetes` 开发者面临多个`runtime`都要接入`kubernetes`导致调用运行时的相关代码接口不稳定的问题。开发者引入一个抽象层对上屏蔽底层的`runtime`实现差异，这个抽象层称为[CRI]([https://kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes/](https://kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes/)), 这里的 `dockershim` 就是二次封装的 docker 的 CRI 实现。

`shim` 这个单词的由来可以从 wiki 上查到 `an application compatibility workaround`。

# kubelet 对POD的处理流程

在 POD 创建过程中大家应该都知道要创建 `sandbox` 用来设置基础网络等等诸多事宜。其实创建 `Sandbox` 这个是 `CRI` 实现的重要功能。

下面是基于 1.17.4 的 `kubelet` 的源码分析，通过源码分析我知道了 `syncLoopIteration` -> `HandlePodAdditions` -> `dispatchWork`->`UpdatePod`-> `managePodLoop`这样的一个函数调用关系

```go
func (p *podWorkers) managePodLoop(podUpdates <-chan UpdatePodOptions) {
	var lastSyncTime time.Time
...
			err = p.syncPodFn(syncPodOptions{ // 就是这个 syncPodFn 函数的实现
				mirrorPod:      update.MirrorPod,
				pod:            update.Pod,
				podStatus:      status,
				killPodOptions: update.KillPodOptions,
				updateType:     update.UpdateType,
			})
```

看一下 `podWorkers` 的结构体构造，其中的 `syncPodFn` 具体实现是` klet.syncPod`函数，可以通过下面这个行代码看出。

```go
klet.podWorkers = newPodWorkers(klet.syncPod, kubeDeps.Recorder, klet.workQueue, klet.resyncInterval, backOffPeriod, klet.podCache)
```

走读代码分析`SyncPod`  这个函数就是就是 `podWorkers`核心了，`worker` 通过 `sync` 函数来调用各个` CRI `接口将这些原子接口组装成一个个实际的` kubernetes` 的` POD`。

```go
// SyncPod syncs the running pod into the desired pod by executing following steps:
//
//  1. Compute sandbox and container changes.
//  2. Kill pod sandbox if necessary.
//  3. Kill any containers that should not be running.
//  4. Create sandbox if necessary.
//  5. Create ephemeral containers.
//  6. Create init containers.
//  7. Create normal containers.
func (m *kubeGenericRuntimeManager) SyncPod(pod *v1.Pod, podStatus *kubecontainer.PodStatus, pullSecrets []v1.Secret, backOff *flowcontrol.Backoff) (result kubecontainer.PodSyncResult) {
	// Step 1: Compute sandbox and container changes.
	podContainerChanges := m.computePodActions(pod, podStatus) // 还是声明式api模型，将操作序列化
...
	// Step 2: Kill the pod if the sandbox has changed.
	if podContainerChanges.KillPod {
...
		killResult := m.killPodWithSyncResult(pod, kubecontainer.ConvertPodStatusToRunningPod(m.runtimeName, podStatus), nil)
... // 删除一下无关紧要的代码，不影响主线逻辑
	} else {
		// Step 3: kill any running containers in this pod which are not to keep.
		for containerID, containerInfo := range podContainerChanges.ContainersToKill {
			klog.V(3).Infof("Killing unwanted container %q(id=%q) for pod %q", containerInfo.name, containerID, format.Pod(pod))
			killContainerResult := kubecontainer.NewSyncResult(kubecontainer.KillContainer, containerInfo.name)
			result.AddSyncResult(killContainerResult)
			if err := m.killContainer(pod, containerID, containerInfo.name, containerInfo.message, nil); err != nil {
...// 一些在运行，但是应该被删除的 container 处理逻辑，
			}
		}
	}
...
  // Step 4: Create a sandbox for the pod if necessary.
	podSandboxID := podContainerChanges.SandboxID
	if podContainerChanges.CreateSandbox {
...
    createSandboxResult := kubecontainer.NewSyncResult(kubecontainer.CreatePodSandbox, format.Pod(pod))
		result.AddSyncResult(createSandboxResult)
		podSandboxID, msg, err = m.createPodSandbox(pod, podContainerChanges.Attempt) 
    // 这个函数是我们关注的核心，准备pod的沙盒，如何在 sandbox 中调用 CNI 设置网络/存储等
... // 删除一下错误处理，事件的逻辑，网络相关，不影响启动一个不使用网络的 container 😄
 
	// Get podSandboxConfig for containers to start.
	configPodSandboxResult := kubecontainer.NewSyncResult(kubecontainer.ConfigPodSandbox, podSandboxID)
	result.AddSyncResult(configPodSandboxResult)
	podSandboxConfig, err := m.generatePodSandboxConfig(pod, podContainerChanges.Attempt)
	if err != nil {
		message := fmt.Sprintf("GeneratePodSandboxConfig for pod %q failed: %v", format.Pod(pod), err)
		klog.Error(message)
		configPodSandboxResult.Fail(kubecontainer.ErrConfigPodSandbox, message)
		return
	}

	// Helper containing boilerplate common to starting all types of containers.
	// typeName is a label used to describe this type of container in log messages,
	// currently: "container", "init container" or "ephemeral container"
	start := func(typeName string, container *v1.Container) error {
		startContainerResult := kubecontainer.NewSyncResult(kubecontainer.StartContainer, container.Name)
		result.AddSyncResult(startContainerResult)

		isInBackOff, msg, err := m.doBackOff(pod, container, podStatus, backOff)
		if isInBackOff {
			startContainerResult.Fail(err, msg)
			klog.V(4).Infof("Backing Off restarting %v %+v in pod %v", typeName, container, format.Pod(pod))
			return err
		}

		klog.V(4).Infof("Creating %v %+v in pod %v", typeName, container, format.Pod(pod))
		// NOTE (aramase) podIPs are populated for single stack and dual stack clusters. Send only podIPs.
		if msg, err := m.startContainer(podSandboxID, podSandboxConfig, container, pod, podStatus, pullSecrets, podIP, podIPs); err != nil { // 创建 cotnainer 和 启动 container 是两回事，创建说的是准备好相关底层文件资源，启动就是以进程形式在OS可见，具体还要看底层运行时是如何实现的。
      // .. 删除了一部分错误处理的逻辑
      
	// Step 5: start ephemeral containers
	//  这部分逻辑非主线

	// Step 6: start the init container.
	if container := podContainerChanges.NextInitContainerToStart; container != nil {
		// Start the next init container.
		if err := start("init container", container); err != nil {
			return
		}

		// Successfully started the container; clear the entry in the failure
		klog.V(4).Infof("Completed init container %q for pod %q", container.Name, format.Pod(pod))
	}

	// Step 7: start containers in podContainerChanges.ContainersToStart. 
	for _, idx := range podContainerChanges.ContainersToStart { // 就是业务的 container 
		start("container", &pod.Spec.Containers[idx]) // start 可以前面看到定义 start := func(typeName string, container *v1.Container) 
	}

	return
}
```

上面的源码走读已经知道了`sandbox`是干嘛的，现在分析一下`createPodSandbox`这个函数的实现吧。实际上用户的 `container`和 `sandbox container` 在本质上没有什么不同，只是 `sandbox` 是第一次启动基础网络配置工作做的多一些。

```go
// createPodSandbox creates a pod sandbox and returns (podSandBoxID, message, error).
func (m *kubeGenericRuntimeManager) createPodSandbox(pod *v1.Pod, attempt uint32) (string, string, error) {
	podSandboxConfig, err := m.generatePodSandboxConfig(pod, attempt)
	if err != nil {
		message := fmt.Sprintf("GeneratePodSandboxConfig for pod %q failed: %v", format.Pod(pod), err)
		klog.Error(message)
		return "", message, err
	}

	// Create pod logs directory
	err = m.osInterface.MkdirAll(podSandboxConfig.LogDirectory, 0755) // 这个目录就是 kubelet 配置读取下来的
	if err != nil {
		message := fmt.Sprintf("Create pod log directory for pod %q failed: %v", format.Pod(pod), err)
... // 省略错误处理	
... // 删除了非主线逻辑
	podSandBoxID, err := m.runtimeService.RunPodSandbox(podSandboxConfig, runtimeHandler)
... // 省略错误处理
	return podSandBoxID, "", nil
}
```

这就是看到调用的 `func (in instrumentedRuntimeService) RunPodSandboxha`函数基本是透传，记录一下 `metric` 为监控服务

```go
func (in instrumentedRuntimeService) RunPodSandbox(config *runtimeapi.PodSandboxConfig, runtimeHandler string) (string, error) {
	const operation = "run_podsandbox"
	startTime := time.Now()
	defer recordOperation(operation, startTime)
	defer metrics.RunPodSandboxDuration.WithLabelValues(runtimeHandler).Observe(metrics.SinceInSeconds(startTime))

	out, err := in.service.RunPodSandbox(config, runtimeHandler)
	recordError(operation, err)
	if err != nil {
		metrics.RunPodSandboxErrors.WithLabelValues(runtimeHandler).Inc()
...
```

在上面记录完成监控相关过后，下面就是准备调用 `grpc` 服务了，可以看到调用的是 `CRI` 的 `/runtime.v1alpha2.RuntimeService/RunPodSandbox` 接口。

```go
// RunPodSandbox creates and starts a pod-level sandbox. Runtimes should ensure
// the sandbox is in ready state.
func (r *RemoteRuntimeService) RunPodSandbox(config *runtimeapi.PodSandboxConfig, runtimeHandler string) (string, error) {
	// Use 2 times longer timeout for sandbox operation (4 mins by default)
	// TODO: Make the pod sandbox timeout configurable.
	ctx, cancel := getContextWithTimeout(r.timeout * 2)
	defer cancel()

	resp, err := r.runtimeClient.RunPodSandbox(ctx, &runtimeapi.RunPodSandboxRequest{
		Config:         config,
		RuntimeHandler: runtimeHandler,
	})
...
	return resp.PodSandboxId, nil
}
```

```go
func (c *runtimeServiceClient) RunPodSandbox(ctx context.Context, in *RunPodSandboxRequest, opts ...grpc.CallOption) (*RunPodSandboxResponse, error) {
	out := new(RunPodSandboxResponse)
	err := c.cc.Invoke(ctx, "/runtime.v1alpha2.RuntimeService/RunPodSandbox", in, out, opts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}
```

以上就是 `kubeGenericRuntimeManager`眼中所看到`POD` 创建的 `sandbox`  的部分，对其`sandbox`创建的更多细节实现就要看 `grpc` 服务端的实现了。

# dockershim 服务端

前面梳理出来了 `kubeGenericRuntimeManager` 是如何通过`SyncPod`实现`POD`的创建，但是也发现他的实现完全是面向接口的，完全不关心底层是如何实现`cotnainer`的。我们接着上面`client`的相关逻辑走读一下`/runtime.v1alpha2.RuntimeService/RunPodSandbox` 的服务端代码逻辑。

```go
var _RuntimeService_serviceDesc = grpc.ServiceDesc{
	ServiceName: "runtime.v1alpha2.RuntimeService",
	HandlerType: (*RuntimeServiceServer)(nil),
	Methods: []grpc.MethodDesc{
...
		{
			MethodName: "RunPodSandbox",
			Handler:    _RuntimeService_RunPodSandbox_Handler,
...
```

下面是 `handler` 注册的过程，其实都是机器生成的代码没有啥好看的。

```go
func _RuntimeService_RunPodSandbox_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(RunPodSandboxRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(RuntimeServiceServer).RunPodSandbox(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: "/runtime.v1alpha2.RuntimeService/RunPodSandbox",
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(RuntimeServiceServer).RunPodSandbox(ctx, req.(*RunPodSandboxRequest))
```

这里就是 `dockershim` 实现的 `CRI`，走读上下文代码知道了 `ds.client.StartContainer()`中的`client`是`libdocker`中，也就是调用的 `dockerClient`。

```go
// RunPodSandbox creates and starts a pod-level sandbox. Runtimes should ensure
// the sandbox is in ready state.
// For docker, PodSandbox is implemented by a container holding the network
// namespace for the pod.
// Note: docker doesn't use LogDirectory (yet).
func (ds *dockerService) RunPodSandbox(ctx context.Context, r *runtimeapi.RunPodSandboxRequest) (*runtimeapi.RunPodSandboxResponse, error) {
	config := r.GetConfig()

	// Step 1: Pull the image for the sandbox.
	image := defaultSandboxImage // 这里就是 Google 的那个 sandbox 的 image
	podSandboxImage := ds.podSandboxImage
	if len(podSandboxImage) != 0 {
		image = podSandboxImage
	}

	// NOTE: To use a custom sandbox image in a private repository, users need to configure the nodes with credentials properly.
	// see: http://kubernetes.io/docs/user-guide/images/#configuring-nodes-to-authenticate-to-a-private-repository
	// Only pull sandbox image when it's not present - v1.PullIfNotPresent.
	if err := ensureSandboxImageExists(ds.client, image); err != nil {
		return nil, err
	}

	// Step 2: Create the sandbox container.
	if r.GetRuntimeHandler() != "" && r.GetRuntimeHandler() != runtimeName {
		return nil, fmt.Errorf("RuntimeHandler %q not supported", r.GetRuntimeHandler())
	}
	createConfig, err := ds.makeSandboxDockerConfig(config, image)
	if err != nil {
		return nil, fmt.Errorf("failed to make sandbox docker config for pod %q: %v", config.Metadata.Name, err)
	}
	createResp, err := ds.client.CreateContainer(*createConfig) // 这里的创建 sandbox 是备好 container 需要底层资源
	if err != nil {
		createResp, err = recoverFromCreationConflictIfNeeded(ds.client, *createConfig, err)
	}

	if err != nil || createResp == nil {
		return nil, fmt.Errorf("failed to create a sandbox for pod %q: %v", config.Metadata.Name, err)
	}
	resp := &runtimeapi.RunPodSandboxResponse{PodSandboxId: createResp.ID}

	ds.setNetworkReady(createResp.ID, false)
	defer func(e *error) {
		// Set networking ready depending on the error return of
		// the parent function
		if *e == nil {
			ds.setNetworkReady(createResp.ID, true)
		}
	}(&err)

	// Step 3: Create Sandbox Checkpoint.
	if err = ds.checkpointManager.CreateCheckpoint(createResp.ID, constructPodSandboxCheckpoint(config)); err != nil {
		return nil, err // 目前来看 checkpoint 功能好像并没有大规模使用？不过这个对我们这次看 pod 创建流程无关经验
	}

	// Step 4: Start the sandbox container.
	// Assume kubelet's garbage collector would remove the sandbox later, if
	// startContainer failed.
	err = ds.client.StartContainer(createResp.ID) // 前面准备好 container 这里才去启动，具体怎么启动 kubelet 并不关心
	if err != nil {
		return nil, fmt.Errorf("failed to start sandbox container for pod %q: %v", config.Metadata.Name, err)
	}

	// 删除了一下网络和安全相关代码和核心流程无关

	// Step 5: Setup networking for the sandbox.
	// All pod networking is setup by a CNI plugin discovered at startup time.
	// This plugin assigns the pod ip, sets up routes inside the sandbox,
	// creates interfaces etc. In theory, its jurisdiction ends with pod
	// sandbox networking, but it might insert iptables rules or open ports
	// on the host as well, to satisfy parts of the pod spec that aren't
	// recognized by the CNI standard yet.
	cID := kubecontainer.BuildContainerID(runtimeName, createResp.ID)
	networkOptions := make(map[string]string)
	if dnsConfig := config.GetDnsConfig(); dnsConfig != nil {
		// Build DNS options.
		dnsOption, err := json.Marshal(dnsConfig)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal dns config for pod %q: %v", config.Metadata.Name, err)
		}
		networkOptions["dns"] = string(dnsOption)
	}
  // CRI 调用 CNI 来设置 POD 的基础网络
	err = ds.network.SetUpPod(config.GetMetadata().Namespace, config.GetMetadata().Name, cID, config.Annotations, networkOptions)

  // 删除了一部分设置容器网络错误的处理流程和核心流程无关

	return resp, nil
}
```

走读的 `dockershim` 的 `RunPodSandbox` 接口发现，它调用了 `docker` 的接口`ds.client.CreateContainer(*createConfig)`创建了`cotnainer`,有使用了`ds.client.StartContainer(createResp.ID)`启动刚刚创建的`cotnainer`。在往下面实现就需要去走读 `dockerd` 的代码了。

## reference

[container-runtime-interface-cri-in-kubernetes/](https://kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes/)