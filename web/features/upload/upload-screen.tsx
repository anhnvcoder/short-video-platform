"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import { useEffect, useEffectEvent, useRef, useState } from "react";
import { DetailsForm } from "@/components/upload/details-form";
import { DropZone } from "@/components/upload/drop-zone";
import { UploadAlert } from "@/components/upload/upload-alert";
import { UploadFrame } from "@/components/upload/upload-frame";
import { UploadProgress } from "@/components/upload/upload-progress";
import { UploadResult } from "@/components/upload/upload-result";
import { loginHref } from "@/features/feed/api";
import { UploadApiError, type Video } from "./api";
import {
  checkFile,
  checkTitle,
  maxDurationSeconds,
  maxTitleLength,
  readDuration,
  titleLength,
  type FileProblem,
  type TitleProblem,
} from "./file-checks";
import { formatDuration, formatMegabytes, secondsLeft } from "./format";
import {
  maxRetries,
  resumableFailures,
  uploadStore,
  useUploads,
  type Upload,
  type UploadFailure,
} from "./upload-store";
import { useVideoStatus } from "./use-video-status";

type UploadScreenProps = {
  // UPLOAD_ORIGIN of the web server: the only host the file may be sent to.
  uploadOrigin: string;
};

type Chosen = { file: File; contentType: string; duration: number | null };

type FileError =
  | { problem: Exclude<FileProblem, "too-large">; name: string }
  | { problem: "too-large"; name: string; size: number }
  | { problem: "too-long"; duration: number };

// Failures shown on the details step, with the file and title kept, so "Post video" starts a new upload.
const detailsAlerts: Partial<
  Record<
    UploadFailure,
    "tooManyUploads" | "rateLimited" | "initFailed" | "badOrigin" | "expired" | "rejected" | "mismatch"
  >
> = {
  "too-many-uploads": "tooManyUploads",
  "rate-limited": "rateLimited",
  "init-failed": "initFailed",
  "bad-origin": "badOrigin",
  expired: "expired",
  rejected: "rejected",
  mismatch: "mismatch",
};

const loginPath = "/upload";

// Still asking for an upload form: no video exists yet, so the details step stays up with its button busy. A wait
// before the form (a rate limit's Retry-After, offline) counts too: it is not a paused upload. During that wait no
// request is out, so "Change file" stays usable: it drops the wait without taking an upload slot.
function isPreparing(upload: Upload): boolean {
  return upload.status === "preparing" || (upload.status === "waiting" && upload.videoId === null);
}

function isActive(upload: Upload): boolean {
  return (
    upload.status === "sending" ||
    (upload.status === "waiting" && !isPreparing(upload)) ||
    upload.status === "completing" ||
    (upload.status === "failed" && upload.failure !== null && resumableFailures.has(upload.failure))
  );
}

// The upload page (docs/adr/0018-web-profiles-public-video-upload.md, section 8; web/design/UploadFlow.dc.html): pick
// and check a file, give it a title, then follow the upload of the tab's store and the processing that follows.
export function UploadScreen({ uploadOrigin }: UploadScreenProps) {
  const t = useTranslations("upload");
  const locale = useLocale();
  const router = useRouter();
  const [chosen, setChosen] = useState<Chosen | null>(null);
  const [checking, setChecking] = useState(false);
  const [fileError, setFileError] = useState<FileError | null>(null);
  const [title, setTitle] = useState("");
  const [titleError, setTitleError] = useState<TitleProblem | null>(null);
  const [key, setKey] = useState<string | null>(null);
  // Only the latest pick counts when the user picks again while a duration is being read.
  const pickId = useRef(0);
  const upload = useUploads().find((candidate) => candidate.key === key);

  const toLogin = useEffectEvent(() => router.replace(loginHref(loginPath)));
  useEffect(() => {
    if (upload?.failure === "unauthorized") {
      toLogin();
    }
  }, [upload?.failure]);

  function forgetUpload() {
    if (key) {
      uploadStore.dismiss(key);
      setKey(null);
    }
  }

  async function pick(file: File) {
    pickId.current += 1;
    const id = pickId.current;
    setFileError(null);
    const check = checkFile(file);
    if (!check.ok) {
      // An earlier pick may still be reading its duration: this pick replaces it, so nothing is being checked now.
      setChecking(false);
      setFileError(
        check.problem === "too-large"
          ? { problem: "too-large", name: file.name, size: file.size }
          : { problem: check.problem, name: file.name },
      );
      return;
    }
    setChecking(true);
    const duration = await readDuration(file);
    if (id !== pickId.current) {
      return;
    }
    setChecking(false);
    if (duration !== null && duration > maxDurationSeconds) {
      setFileError({ problem: "too-long", duration });
      return;
    }
    forgetUpload();
    setChosen({ file, contentType: check.contentType, duration });
  }

  function changeFile() {
    forgetUpload();
    setChosen(null);
  }

  function submit() {
    if (!chosen) {
      return;
    }
    const problem = checkTitle(title);
    setTitleError(problem);
    if (problem) {
      return;
    }
    forgetUpload();
    setKey(
      uploadStore.start({
        file: chosen.file,
        title: title.trim(),
        contentType: chosen.contentType,
        uploadOrigin,
      }),
    );
  }

  function restart() {
    forgetUpload();
    setChosen(null);
    setTitle("");
    setTitleError(null);
    setFileError(null);
  }

  const megabytes = (bytes: number) => formatMegabytes(bytes, locale);
  const fileMeta = (name: string, size: number) => `${name} · ${t("details.size", { size: megabytes(size) })}`;

  if (upload?.status === "processing" && upload.video) {
    return (
      <UploadFrame step={3}>
        <Processing
          video={upload.video}
          videoId={upload.videoId ?? upload.video.video_id}
          fileMeta={fileMeta(upload.fileName, upload.sizeBytes)}
          onRestart={restart}
          onUnauthorized={() => router.replace(loginHref(loginPath))}
        />
      </UploadFrame>
    );
  }

  if (upload && isActive(upload)) {
    return (
      <UploadFrame step={3}>
        <Progress upload={upload} megabytes={megabytes} fileMeta={fileMeta(upload.fileName, upload.sizeBytes)} />
      </UploadFrame>
    );
  }

  if (chosen) {
    const failure = upload?.status === "failed" ? upload.failure : null;
    const alertKey = failure ? detailsAlerts[failure] : undefined;
    let alert = null;
    if (alertKey) {
      alert = (
        <UploadAlert
          tone={failure === "too-many-uploads" || failure === "rate-limited" ? "warning" : "danger"}
          title={t(`failure.${alertKey}.title`)}
          body={t(`failure.${alertKey}.body`)}
        >
          {failure === "too-many-uploads" && (
            <Link href="/me" className="pt-2 pb-0.5 font-semibold">
              {t("failure.tooManyUploads.link")}
            </Link>
          )}
        </UploadAlert>
      );
    } else if (upload?.status === "cancelled") {
      alert = <UploadAlert tone="warning" title={t("cancelled.title")} body={t("cancelled.body")} />;
    } else if (upload?.status === "waiting" && upload.waitingFor === "online") {
      // A wait before the form (any later one shows the progress step): the request goes out once the browser is
      // online again.
      alert = <UploadAlert tone="offline" title={t("progress.offline.title")} body={t("progress.offline.body")} />;
    } else if (upload?.status === "waiting" && upload.waitingFor === "backoff") {
      // Before the form only a rate limit is retried by itself: the gateway refused the request, so no video exists.
      alert = (
        <UploadAlert
          tone="warning"
          title={t("failure.rateLimited.title")}
          body={t("progress.retrying.body", { retry: upload.retries, max: maxRetries })}
        />
      );
    }
    const size = megabytes(chosen.file.size);
    const duration = chosen.duration === null ? null : formatDuration(chosen.duration);
    return (
      <UploadFrame step={2}>
        <DetailsForm
          fileName={chosen.file.name}
          fileMeta={duration ? t("details.sizeAndDuration", { size, duration }) : t("details.size", { size })}
          duration={duration}
          title={title}
          onTitleChange={setTitle}
          titleLength={titleLength(title)}
          maxTitleLength={maxTitleLength}
          titleError={
            titleError === "required" ? t("details.titleRequired") : titleError ? t("details.titleTooLong") : null
          }
          onChangeFile={changeFile}
          onSubmit={submit}
          submitting={upload ? isPreparing(upload) : false}
          requesting={upload?.status === "preparing"}
          alert={alert}
        />
      </UploadFrame>
    );
  }

  return (
    <UploadFrame step={1}>
      {fileError && <FileErrorAlert error={fileError} megabytes={megabytes} />}
      <DropZone onFile={(file) => void pick(file)} checking={checking} />
    </UploadFrame>
  );
}

function FileErrorAlert({ error, megabytes }: { error: FileError; megabytes: (bytes: number) => string }) {
  const t = useTranslations("upload.fileError");
  switch (error.problem) {
    case "too-large":
      return (
        <UploadAlert
          tone="danger"
          title={t("tooLarge.title")}
          body={t("tooLarge.body", { name: error.name, size: megabytes(error.size) })}
        />
      );
    case "too-long":
      return (
        <UploadAlert
          tone="danger"
          title={t("tooLong.title")}
          body={t("tooLong.body", { duration: formatDuration(error.duration) })}
        />
      );
    case "not-video":
      return <UploadAlert tone="danger" title={t("notVideo.title")} body={t("notVideo.body", { name: error.name })} />;
    case "empty":
      return <UploadAlert tone="danger" title={t("empty.title")} body={t("empty.body", { name: error.name })} />;
  }
}

function Progress({
  upload,
  megabytes,
  fileMeta,
}: {
  upload: Upload;
  megabytes: (bytes: number) => string;
  fileMeta: string;
}) {
  const t = useTranslations("upload");
  const sent = megabytes(upload.sizeBytes * upload.progress);
  const total = megabytes(upload.sizeBytes);
  const sizes = t("progress.meta", { loaded: sent, total });

  let heading: string;
  let meta: string;
  if (upload.status === "sending") {
    heading = t("progress.sending", { percent: Math.round(upload.progress * 100) });
    const parts = [sizes];
    if (upload.bytesPerSecond !== null) {
      parts.push(t("progress.speed", { speed: megabytes(upload.bytesPerSecond) }));
      const left = secondsLeft(upload.sizeBytes, upload.progress, upload.bytesPerSecond);
      if (left !== null) {
        parts.push(
          left < 60
            ? t("progress.secondsLeft", { seconds: left })
            : t("progress.minutesLeft", { minutes: Math.ceil(left / 60) }),
        );
      }
    }
    meta = parts.join(" · ");
  } else if (upload.status === "completing") {
    heading = t("progress.completing");
    meta = sizes;
  } else {
    heading = t("progress.waiting");
    meta = `${sizes} · ${t("progress.paused")}`;
  }

  let alert = null;
  if (upload.status === "failed") {
    const key = upload.failure === "complete-failed" ? "completeFailed" : "sendFailed";
    alert = <UploadAlert tone="danger" title={t(`failure.${key}.title`)} body={t(`failure.${key}.body`)} />;
  } else if (upload.waitingFor === "online") {
    alert = <UploadAlert tone="offline" title={t("progress.offline.title")} body={t("progress.offline.body")} />;
  } else if (upload.waitingFor === "backoff") {
    alert = (
      <UploadAlert
        tone="offline"
        title={t("progress.retrying.title")}
        body={t("progress.retrying.body", { retry: upload.retries, max: maxRetries })}
      />
    );
  } else if (upload.renewed) {
    alert = <UploadAlert tone="warning" title={t("progress.renewed.title")} body={t("progress.renewed.body")} />;
  }

  return (
    <UploadProgress
      heading={heading}
      progress={upload.progress}
      paused={upload.status !== "sending"}
      meta={meta}
      videoTitle={upload.title}
      fileMeta={fileMeta}
      alert={alert}
      onCancel={() => uploadStore.cancel(upload.key)}
      onRetry={upload.status === "failed" ? () => uploadStore.retry(upload.key) : undefined}
    />
  );
}

// Polls the video until the worker is done; unmounting stops the polling.
function Processing({
  video,
  videoId,
  fileMeta,
  onRestart,
  onUnauthorized,
}: {
  video: Video;
  // Checked as a canonical UUID when the upload form came.
  videoId: string;
  fileMeta: string;
  onRestart: () => void;
  onUnauthorized: () => void;
}) {
  const { data, error } = useVideoStatus(video);
  const unauthorized = error instanceof UploadApiError && error.status === 401;
  const toLogin = useEffectEvent(onUnauthorized);
  useEffect(() => {
    if (unauthorized) {
      toLogin();
    }
  }, [unauthorized]);

  const state = data.status === "READY" ? "ready" : data.status === "FAILED" ? "failed" : "processing";
  return (
    <UploadResult
      state={state}
      fileMeta={fileMeta}
      videoHref={state === "ready" ? `/v/${videoId}` : null}
      onRestart={onRestart}
    />
  );
}
