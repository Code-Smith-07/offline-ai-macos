import WorkerInstance from '$lib/workers/kokoro.worker?worker';

export class KokoroWorker {
	private worker: Worker | null = null;
	private initialized: boolean = false;
	private readonly dtype = 'q8';
	private initPromise: Promise<void> | null = null;
	private initResolve: (() => void) | null = null;
	private initReject: ((reason: Error) => void) | null = null;
	private initTimer: ReturnType<typeof setTimeout> | null = null;
	private requestQueue: Array<{
		text: string;
		voice: string;
		resolve: (value: string) => void;
		reject: (reason: any) => void;
		timer: ReturnType<typeof setTimeout>;
	}> = [];
	private processing = false; // To track if a request is being processed

	constructor(_options: string | { dtype?: string } = 'q8') {}

	public async init(): Promise<void> {
		if (this.initialized && this.worker) {
			return;
		}
		if (this.initPromise) return this.initPromise;

		this.worker = new WorkerInstance();

		// Handle worker messages
		this.worker.onmessage = (event) => {
			const { status, error, audioUrl, audioBlob } = event.data;

			if (status === 'init:complete') {
				this.initialized = true;
				this.clearInitTimer();
				this.initResolve?.();
				this.clearInitPromise();
			} else if (status === 'init:error') {
				this.failWorker(new Error(error || 'Natural voice could not be loaded'));
			} else if (status === 'generate:complete') {
				// Resolve promise from queue
				const request = this.requestQueue.shift();
				if (request) {
					clearTimeout(request.timer);
					// Blob URLs created inside a worker are not consistently playable in
					// WKWebView. Create the URL in the window that owns the audio element.
					request.resolve(audioBlob ? URL.createObjectURL(audioBlob) : audioUrl);
					this.processNextRequest(); // Process next request in queue
				}
			} else if (status === 'generate:error') {
				const request = this.requestQueue.shift();
				if (request) {
					clearTimeout(request.timer);
					request.reject(new Error(error));
					this.processNextRequest(); // Continue processing next in queue
				}
			}
		};
		this.worker.onerror = (event) => {
			this.failWorker(new Error(event.message || 'Natural voice worker crashed'));
		};
		this.worker.onmessageerror = () => {
			this.failWorker(new Error('Natural voice worker returned an unreadable response'));
		};

		this.initPromise = new Promise<void>((resolve, reject) => {
			this.initResolve = resolve;
			this.initReject = reject;
			this.initTimer = setTimeout(() => {
				this.failWorker(
					new Error('Natural voice loading timed out. Falling back to the macOS voice.')
				);
			}, 90_000);

			this.worker!.postMessage({
				type: 'init',
				payload: { dtype: this.dtype }
			});
		});

		return this.initPromise;
	}

	public async generate({ text, voice }: { text: string; voice: string }): Promise<string> {
		if (!this.initialized || !this.worker) {
			await this.init();
		}

		return new Promise<string>((resolve, reject) => {
			const request = {
				text,
				voice,
				resolve,
				reject,
				timer: setTimeout(() => {
					this.failWorker(new Error('Natural voice generation timed out'));
				}, 90_000)
			};
			this.requestQueue.push(request);
			if (!this.processing) {
				this.processNextRequest();
			}
		});
	}

	private processNextRequest() {
		if (this.requestQueue.length === 0) {
			this.processing = false;
			return;
		}

		this.processing = true;
		const { text, voice } = this.requestQueue[0]; // Get first request but don't remove yet
		this.worker!.postMessage({ type: 'generate', payload: { text, voice } });
	}

	private clearInitTimer() {
		if (this.initTimer) clearTimeout(this.initTimer);
		this.initTimer = null;
	}

	private clearInitPromise() {
		this.initPromise = null;
		this.initResolve = null;
		this.initReject = null;
	}

	private failWorker(error: Error) {
		this.clearInitTimer();
		this.initReject?.(error);
		this.clearInitPromise();

		for (const request of this.requestQueue.splice(0)) {
			clearTimeout(request.timer);
			request.reject(error);
		}

		this.worker?.terminate();
		this.worker = null;
		this.initialized = false;
		this.processing = false;
	}

	public terminate() {
		this.failWorker(new Error('Natural voice was stopped'));
	}
}
