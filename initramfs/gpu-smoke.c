// SPDX-License-Identifier: MIT
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <drm/msm_drm.h>
#include <gbm.h>
#include <xf86drm.h>

static void fail(const char *message)
{
	fprintf(stderr, "FAIL: %s\n", message);
	exit(EXIT_FAILURE);
}

static uint64_t get_msm_param(int fd, uint32_t param)
{
	struct drm_msm_param request = {
		.pipe = MSM_PIPE_3D0,
		.param = param,
	};

	if (drmCommandWriteRead(fd, DRM_MSM_GET_PARAM, &request,
				sizeof(request)) < 0) {
		fprintf(stderr, "GET_PARAM %#x failed: %s\n", param,
			strerror(errno));
		exit(EXIT_FAILURE);
	}

	return request.value;
}

static GLuint compile_shader(GLenum type, const char *source)
{
	GLuint shader = glCreateShader(type);
	GLint ok;

	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024];

		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		fprintf(stderr, "Shader compile failed: %s\n", log);
		exit(EXIT_FAILURE);
	}

	return shader;
}

int main(void)
{
	static const GLfloat vertices[] = {
		-1.0f, -1.0f,
		 3.0f, -1.0f,
		-1.0f,  3.0f,
	};
	static const char vertex_source[] =
		"attribute vec2 position;"
		"void main() { gl_Position = vec4(position, 0.0, 1.0); }";
	static const char fragment_source[] =
		"precision mediump float;"
		"void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }";
	const EGLint config_attributes[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8,
		EGL_GREEN_SIZE, 8,
		EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 8,
		EGL_NONE,
	};
	const EGLint surface_attributes[] = {
		EGL_WIDTH, 64,
		EGL_HEIGHT, 64,
		EGL_NONE,
	};
	const EGLint context_attributes[] = {
		EGL_CONTEXT_CLIENT_VERSION, 2,
		EGL_NONE,
	};
	drmVersionPtr version;
	struct gbm_device *gbm;
	EGLDisplay display;
	EGLConfig config;
	EGLSurface surface;
	EGLContext context;
	EGLint major, minor, count;
	GLuint texture, framebuffer, vertex, fragment, program;
	GLint position;
	uint8_t pixel[4] = { 0 };
	uint64_t gpu_id, chip_id, faults_before, faults_after;
	const char *renderer;
	int fd;

	fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	if (fd < 0)
		fail("cannot open /dev/dri/renderD128");

	version = drmGetVersion(fd);
	if (!version)
		fail("DRM_IOCTL_VERSION failed");
	printf("DRM driver: %s %d.%d.%d\n", version->name,
	       version->version_major, version->version_minor,
	       version->version_patchlevel);
	if (strcmp(version->name, "msm"))
		fail("render node is not driven by msm");
	drmFreeVersion(version);

	gpu_id = get_msm_param(fd, MSM_PARAM_GPU_ID);
	chip_id = get_msm_param(fd, MSM_PARAM_CHIP_ID);
	faults_before = get_msm_param(fd, MSM_PARAM_FAULTS);
	printf("GPU_ID: %llu\nCHIP_ID: %#llx\nFAULTS before: %llu\n",
	       (unsigned long long)gpu_id, (unsigned long long)chip_id,
	       (unsigned long long)faults_before);
	if (gpu_id != 512 || chip_id != 0x05010200)
		fail("unexpected Adreno identity");

	gbm = gbm_create_device(fd);
	if (!gbm)
		fail("gbm_create_device failed");
	display = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor))
		fail("EGL initialization failed");
	printf("EGL: %d.%d\n", major, minor);
	if (!eglBindAPI(EGL_OPENGL_ES_API))
		fail("eglBindAPI failed");
	if (!eglChooseConfig(display, config_attributes, &config, 1, &count) ||
	    count != 1)
		fail("no EGL pbuffer config");
	surface = eglCreatePbufferSurface(display, config, surface_attributes);
	context = eglCreateContext(display, config, EGL_NO_CONTEXT,
				   context_attributes);
	if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
	    !eglMakeCurrent(display, surface, surface, context))
		fail("cannot create current GLES2 context");

	renderer = (const char *)glGetString(GL_RENDERER);
	printf("GL_VENDOR: %s\nGL_RENDERER: %s\nGL_VERSION: %s\n",
	       glGetString(GL_VENDOR), renderer, glGetString(GL_VERSION));
	if (!renderer || strstr(renderer, "llvmpipe") ||
	    strstr(renderer, "softpipe"))
		fail("software renderer detected");

	glGenTextures(1, &texture);
	glBindTexture(GL_TEXTURE_2D, texture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 64, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenFramebuffers(1, &framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
			       GL_TEXTURE_2D, texture, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		fail("off-screen framebuffer is incomplete");

	vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
	fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
	program = glCreateProgram();
	glAttachShader(program, vertex);
	glAttachShader(program, fragment);
	glLinkProgram(program);
	glUseProgram(program);
	position = glGetAttribLocation(program, "position");
	glVertexAttribPointer(position, 2, GL_FLOAT, GL_FALSE, 0, vertices);
	glEnableVertexAttribArray(position);
	glViewport(0, 0, 64, 64);
	glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glFinish();
	glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
	printf("Center pixel: %u,%u,%u,%u\n", pixel[0], pixel[1],
	       pixel[2], pixel[3]);
	if (pixel[0] > 8 || pixel[1] < 247 || pixel[2] > 8 || pixel[3] < 247)
		fail("shader draw/readback mismatch");

	faults_after = get_msm_param(fd, MSM_PARAM_FAULTS);
	printf("FAULTS after: %llu\n", (unsigned long long)faults_after);
	if (faults_after != faults_before)
		fail("GPU fault count increased");

	printf("PASS: Adreno 512 Freedreno draw/readback\n");
	return EXIT_SUCCESS;
}
