use anyhow::Result;
use pxder::{
    api::{self, Api, Endpoints},
    config::Config,
    download::{self, Progress, Request, Source},
    model::DownloadTask,
};
use serde_json::json;
use std::{path::Path, time::Duration};
use tokio_util::sync::CancellationToken;
use wiremock::{
    Mock, MockServer, ResponseTemplate,
    matchers::{body_string_contains, header, method, path, query_param},
};

fn config(dir: &Path) -> Config {
    let mut config = Config::default();
    config.download.path = Some(dir.to_owned());
    config.download.thread = 2;
    config.download.timeout = 2;
    config.refresh_token = Some("test-refresh".into());
    config.proxy = Some("disable".into());
    config
}
async fn api(server: &MockServer, config: &Config, cancel: CancellationToken) -> Result<Api> {
    Mock::given(method("POST")).and(path("/auth/token")).and(body_string_contains("grant_type=refresh_token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"access_token":"test-access","refresh_token":"rotated-refresh","expires_in":3600,"user":{"id":"7"}})))
        .mount(server).await;
    Api::login(
        config,
        None,
        Endpoints {
            api: server.uri().parse()?,
            oauth: format!("{}/auth/token", server.uri()).parse()?,
        },
        cancel,
        None,
    )
    .await
}
fn illustration(server: &MockServer, id: u64) -> serde_json::Value {
    json!({"id": id, "title": "猫", "type":"illust", "meta_single_page":{"original_image_url":format!("{}/{id}.png",server.uri())}})
}

#[tokio::test]
async fn private_bookmarks_paginate_download_and_skip_without_second_transfer() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    let config = config(dir.path());
    let cancel = CancellationToken::new();
    let api = api(&server, &config, cancel.clone()).await?;
    Mock::given(method("GET")).and(path("/v1/user/bookmarks/illust")).and(query_param("restrict", "private")).and(query_param("user_id", "7"))
        .and(header("authorization", "Bearer test-access"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"illusts":[illustration(&server, 10)],"next_url":format!("{}/page2",server.uri())}))).expect(2).mount(&server).await;
    Mock::given(path("/page2"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"illusts":[illustration(&server, 11)],"next_url":null})),
        )
        .expect(2)
        .mount(&server)
        .await;
    for id in [10, 11] {
        Mock::given(path(format!("/{id}.png")))
            .and(header("referer", "https://www.pixiv.net/"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![7; 9001]))
            .expect(1)
            .mount(&server)
            .await;
    }
    for round in 0..2 {
        let (progress, _) = Progress::new();
        let result = download::run(
            api.clone(),
            config.clone(),
            Request {
                source: Source::Bookmarks { private: true },
                no_ugoira_meta: false,
            },
            cancel.clone(),
            progress,
        )
        .await?;
        assert_eq!(result.queued, 2);
        assert_eq!(result.succeeded, if round == 0 { 2 } else { 0 });
        assert_eq!(result.skipped, if round == 0 { 0 } else { 2 });
        assert!(!result.has_errors());
    }
    assert_eq!(
        std::fs::read(dir.path().join("[bookmark] Private/(10)猫.png"))?,
        vec![7; 9001]
    );
    server.verify().await;
    Ok(())
}

#[tokio::test]
async fn source_failure_is_reported_even_when_download_queue_is_empty() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    let cfg = config(dir.path());
    let cancel = CancellationToken::new();
    let api = api(&server, &cfg, cancel.clone()).await?;
    Mock::given(path("/v1/illust/detail"))
        .respond_with(ResponseTemplate::new(403))
        .mount(&server)
        .await;
    let (progress, _) = Progress::new();
    let result = download::run(
        api,
        cfg,
        Request {
            source: Source::Pids(vec![1]),
            no_ugoira_meta: false,
        },
        cancel,
        progress,
    )
    .await?;
    assert!(result.has_errors());
    assert_eq!(result.source_errors, 1);
    assert_eq!(result.queued, 0);
    Ok(())
}

#[tokio::test]
async fn foreign_pagination_never_receives_credentials() -> Result<()> {
    let server = MockServer::start().await;
    let foreign = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    let cfg = config(dir.path());
    let cancel = CancellationToken::new();
    let api = api(&server, &cfg, cancel.clone()).await?;
    Mock::given(path("/v1/user/bookmarks/illust"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"illusts":[],"next_url":foreign.uri()})),
        )
        .mount(&server)
        .await;
    let (progress, _) = Progress::new();
    let result = download::run(
        api,
        cfg,
        Request {
            source: Source::Bookmarks { private: false },
            no_ugoira_meta: false,
        },
        cancel,
        progress,
    )
    .await?;
    assert_eq!(result.source_errors, 1);
    assert!(
        foreign
            .received_requests()
            .await
            .unwrap_or_default()
            .is_empty()
    );
    Ok(())
}

#[tokio::test]
async fn http_404_skips_and_403_fails_without_retry() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    for status in [404, 403] {
        Mock::given(path(format!("/{status}")))
            .respond_with(ResponseTemplate::new(status))
            .expect(1)
            .mount(&server)
            .await;
        let task = DownloadTask {
            pid: 1,
            url: format!("{}/{status}", server.uri()),
            path: dir.path().join(format!("{status}.jpg")),
            frames: None,
        };
        let (progress, _) = Progress::new();
        let result = download::download_file(
            &api::http_client(&config(dir.path()))?,
            &task,
            &CancellationToken::new(),
            &progress,
        )
        .await;
        if status == 404 {
            assert!(!result?);
        } else {
            assert!(result.is_err());
        }
        assert!(!task.path.exists());
    }
    server.verify().await;
    Ok(())
}

#[tokio::test]
async fn retry_after_is_honored_and_then_download_succeeds() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    Mock::given(path("/image"))
        .respond_with(ResponseTemplate::new(429).insert_header("Retry-After", "0"))
        .up_to_n_times(1)
        .with_priority(1)
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(path("/image"))
        .respond_with(ResponseTemplate::new(200).set_body_string("complete image"))
        .with_priority(2)
        .expect(1)
        .mount(&server)
        .await;
    let task = DownloadTask {
        pid: 1,
        url: format!("{}/image", server.uri()),
        path: dir.path().join("image.jpg"),
        frames: None,
    };
    let (progress, _) = Progress::new();
    assert!(
        download::download_file(
            &api::http_client(&config(dir.path()))?,
            &task,
            &CancellationToken::new(),
            &progress
        )
        .await?
    );
    assert_eq!(std::fs::read_to_string(&task.path)?, "complete image");
    server.verify().await;
    Ok(())
}

#[tokio::test]
async fn cancellation_interrupts_retry_after_and_preserves_no_final_file() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    Mock::given(path("/image"))
        .respond_with(ResponseTemplate::new(429).insert_header("Retry-After", "600"))
        .expect(1)
        .mount(&server)
        .await;
    let task = DownloadTask {
        pid: 1,
        url: format!("{}/image", server.uri()),
        path: dir.path().join("image.jpg"),
        frames: None,
    };
    let (progress, _) = Progress::new();
    let cancel = CancellationToken::new();
    let signal = cancel.clone();
    let worker = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        signal.cancel();
    });
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        download::download_file(
            &api::http_client(&config(dir.path()))?,
            &task,
            &cancel,
            &progress,
        ),
    )
    .await?;
    worker.await?;
    assert!(result.is_err());
    assert!(!task.path.exists());
    assert_eq!(std::fs::read_dir(dir.path())?.count(), 0);
    Ok(())
}

#[tokio::test]
async fn slow_body_cancellation_cleans_partial_file() -> Result<()> {
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await?;
        let mut buf = [0; 4096];
        let _ = socket.read(&mut buf).await?;
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\npartial")
            .await?;
        tokio::time::sleep(Duration::from_secs(10)).await;
        Ok::<_, std::io::Error>(())
    });
    let dir = tempfile::tempdir()?;
    let task = DownloadTask {
        pid: 1,
        url: format!("http://{addr}/image"),
        path: dir.path().join("image.jpg"),
        frames: None,
    };
    let (progress, _) = Progress::new();
    let cancel = CancellationToken::new();
    let signal = cancel.clone();
    let worker = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        signal.cancel();
    });
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        download::download_file(
            &api::http_client(&config(dir.path()))?,
            &task,
            &cancel,
            &progress,
        ),
    )
    .await?;
    worker.await?;
    server.abort();
    assert!(result.is_err());
    assert!(!task.path.exists());
    // Dropping an in-flight file write must not leave a published partial image.
    assert_eq!(std::fs::read_dir(dir.path())?.count(), 0);
    Ok(())
}

#[tokio::test]
async fn connection_close_body_with_non_buffer_sized_tail_is_complete() -> Result<()> {
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let expected = vec![42u8; 8192 + 17];
    let body = expected.clone();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await?;
        let mut buf = [0; 4096];
        let _ = socket.read(&mut buf).await?;
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
            .await?;
        socket.write_all(&body).await?;
        Ok::<_, std::io::Error>(())
    });
    let dir = tempfile::tempdir()?;
    let task = DownloadTask {
        pid: 1,
        url: format!("http://{addr}/image"),
        path: dir.path().join("image.jpg"),
        frames: None,
    };
    let (progress, _) = Progress::new();
    assert!(
        download::download_file(
            &api::http_client(&config(dir.path()))?,
            &task,
            &CancellationToken::new(),
            &progress
        )
        .await?
    );
    server.await??;
    assert_eq!(std::fs::read(task.path)?, expected);
    Ok(())
}

#[tokio::test]
async fn existing_file_is_never_overwritten() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let task = DownloadTask {
        pid: 1,
        url: "http://127.0.0.1:1/no-request".into(),
        path: dir.path().join("image.jpg"),
        frames: None,
    };
    std::fs::write(&task.path, b"original")?;
    let (progress, _) = Progress::new();
    assert!(
        !download::download_file(
            &api::http_client(&config(dir.path()))?,
            &task,
            &CancellationToken::new(),
            &progress
        )
        .await?
    );
    assert_eq!(std::fs::read(task.path)?, b"original");
    Ok(())
}

#[tokio::test]
async fn private_following_renames_artist_and_fetches_correct_scope() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    std::fs::create_dir(dir.path().join("(42)旧名字"))?;
    std::fs::write(dir.path().join("(42)旧名字/keep.txt"), "keep")?;
    let mut cfg = config(dir.path());
    cfg.download.auto_rename = true;
    let cancel = CancellationToken::new();
    let api = api(&server, &cfg, cancel.clone()).await?;
    Mock::given(path("/v1/user/following"))
        .and(query_param("restrict", "private"))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"user_previews":[{"user":{"id":42,"name":"新名字@展位"}}],"next_url":null}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(path("/v1/user/illusts"))
        .and(query_param("user_id", "42"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"illusts":[],"next_url":null})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let (progress, _) = Progress::new();
    let result = download::run(
        api,
        cfg,
        Request {
            source: Source::Following { private: true },
            no_ugoira_meta: false,
        },
        cancel,
        progress,
    )
    .await?;
    assert!(!result.has_errors());
    assert_eq!(
        std::fs::read_to_string(dir.path().join("(42)新名字/keep.txt"))?,
        "keep"
    );
    assert!(!dir.path().join("(42)旧名字").exists());
    server.verify().await;
    Ok(())
}

#[tokio::test]
async fn unauthorized_response_refreshes_token_and_retries_once() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    let cfg = config(dir.path());
    let cancel = CancellationToken::new();
    let api = api(&server, &cfg, cancel).await?;
    Mock::given(path("/auth/token"))
        .and(body_string_contains("refresh_token=rotated-refresh"))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"access_token":"new-access","refresh_token":"new-refresh","user":{"id":7}}),
        ))
        .with_priority(1)
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(path("/v1/illust/detail"))
        .and(header("authorization", "Bearer test-access"))
        .respond_with(ResponseTemplate::new(401))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(path("/v1/illust/detail"))
        .and(header("authorization", "Bearer new-access"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"illust":illustration(&server, 1)})),
        )
        .expect(1)
        .mount(&server)
        .await;
    assert_eq!(api.detail(1).await?.id, 1);
    server.verify().await;
    Ok(())
}

#[tokio::test]
async fn worker_pool_never_exceeds_configured_concurrency() -> Result<()> {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let server_peak = peak.clone();
    let server_active = active.clone();
    let images = tokio::spawn(async move {
        let mut handles = Vec::new();
        for _ in 0..6 {
            let (mut socket, _) = listener.accept().await?;
            let peak = server_peak.clone();
            let active = server_active.clone();
            handles.push(tokio::spawn(async move {
                let mut buf = [0; 4096];
                let _ = socket.read(&mut buf).await?;
                let count = active.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(count, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(80)).await;
                socket
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nimage",
                    )
                    .await?;
                active.fetch_sub(1, Ordering::SeqCst);
                Ok::<_, anyhow::Error>(())
            }));
        }
        for handle in handles {
            handle.await??;
        }
        Ok::<_, anyhow::Error>(())
    });
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    let cfg = config(dir.path());
    let cancel = CancellationToken::new();
    let api = api(&server, &cfg, cancel.clone()).await?;
    for id in 1..=6 {
        Mock::given(path("/v1/illust/detail")).and(query_param("illust_id", id.to_string()))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"illust":{"id":id,"title":"image","meta_single_page":{"original_image_url":format!("http://{addr}/{id}.png")}}}))).mount(&server).await;
    }
    let (progress, _) = Progress::new();
    let result = download::run(
        api,
        cfg,
        Request {
            source: Source::Pids((1..=6).collect()),
            no_ugoira_meta: false,
        },
        cancel,
        progress,
    )
    .await?;
    images.await??;
    assert_eq!(result.succeeded, 6);
    assert!(!result.has_errors());
    assert_eq!(peak.load(Ordering::SeqCst), 2);
    Ok(())
}

#[tokio::test]
async fn configured_timeout_applies_to_network_requests() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    let mut cfg = config(dir.path());
    cfg.download.timeout = 1;
    Mock::given(path("/slow"))
        .respond_with(ResponseTemplate::new(200).set_delay(Duration::from_secs(10)))
        .mount(&server)
        .await;
    let start = std::time::Instant::now();
    let result = api::http_client(&cfg)?
        .get(format!("{}/slow", server.uri()))
        .send()
        .await;
    assert!(result.is_err_and(|error| error.is_timeout()));
    assert!(start.elapsed() < Duration::from_secs(3));
    Ok(())
}

#[tokio::test]
async fn api_retries_are_bounded() -> Result<()> {
    let server = MockServer::start().await;
    let dir = tempfile::tempdir()?;
    let api = api(&server, &config(dir.path()), CancellationToken::new()).await?;
    Mock::given(path("/v1/illust/detail"))
        .respond_with(ResponseTemplate::new(503).insert_header("Retry-After", "0"))
        .expect(4)
        .mount(&server)
        .await;
    assert!(api.detail(1).await.is_err());
    server.verify().await;
    Ok(())
}
