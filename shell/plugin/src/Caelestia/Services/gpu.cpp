#include "gpu.hpp"

#include <qdir.h>
#include <qdiriterator.h>
#include <qfile.h>
#include <qregularexpression.h>

#include <QTimer>
#include <array>
#include <cmath>
#include <functional>

#include "../Config/rootnodes.hpp"
#include "../Config/serviceconfig.hpp"
#include "sensorslib.hpp"

namespace caelestia::services {

namespace {

// A card with a busy-percent node is a GPU we can read usage from without a vendor tool
QStringList gpuBusyFiles() {
    static const QRegularExpression cardRe(QStringLiteral("^card\\d+$"));

    QStringList files;
    QDirIterator it(QStringLiteral("/sys/class/drm"), QDir::Dirs | QDir::NoDotAndDotDot);
    while (it.hasNext()) {
        const QString path = it.next();
        if (!cardRe.match(it.fileName()).hasMatch()) {
            continue;
        }
        const QString busy = path + QStringLiteral("/device/gpu_busy_percent");
        if (QFile::exists(busy)) {
            files << busy;
        }
    }
    return files;
}

// Intel iGPUs expose no busy-percent node, so their frequency nodes are what tells
// them apart from a machine with no GPU at all
bool hasIntelGpu() {
    static const QRegularExpression cardRe(QStringLiteral("^card\\d+$"));

    QDirIterator it(QStringLiteral("/sys/class/drm"), QDir::Dirs | QDir::NoDotAndDotDot);
    while (it.hasNext()) {
        const QString path = it.next();
        if (!cardRe.match(it.fileName()).hasMatch()) {
            continue;
        }
        if (QFile::exists(path + QStringLiteral("/gt/gt0/rps_cur_freq_mhz"))) {
            return true;
        }
    }
    return false;
}

// Qualcomm Adreno through the kgsl sysfs class: containers that expose only a
// render node have no DRM card dir at all, so kgsl is the only place usage can
// come from there (anland/droidspaces is exactly that case)
bool hasKgslGpu() {
    return QFile::exists(QStringLiteral("/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"))
        || QFile::exists(QStringLiteral("/sys/class/kgsl/kgsl-3d0/gpubusy"));
}

QString cleanName(QString s) {
    static const QRegularExpression noise(
        QStringLiteral("\\(R\\)|\\(TM\\)|Graphics"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression spaces(QStringLiteral("\\s+"));
    s.replace(noise, QString());
    s.replace(spaces, QStringLiteral(" "));
    return s.trimmed();
}

QString parseNvidiaName(const QByteArray& out) {
    const QString first = QString::fromUtf8(out).split(u'\n').value(0).trimmed();
    return first.isEmpty() ? QString() : cleanName(first);
}

QString parseGlxinfoName(const QByteArray& out) {
    const QStringList lines = QString::fromUtf8(out).split(u'\n');
    for (const QString& line : lines) {
        const qsizetype idx = line.indexOf(QStringLiteral("Device:"));
        if (idx < 0) {
            continue;
        }

        QString rest = line.mid(idx + 7);
        const qsizetype paren = rest.indexOf(u'(');
        if (paren >= 0) {
            rest = rest.left(paren);
        }

        const QString cleaned = cleanName(rest);
        if (!cleaned.isEmpty()) {
            return cleaned;
        }
    }

    return QString();
}

QString parseLspciName(const QByteArray& out) {
    static const QRegularExpression lineRe(
        QStringLiteral("vga|3d controller|display"), QRegularExpression::CaseInsensitiveOption);

    const QStringList lines = QString::fromUtf8(out).split(u'\n');
    QString match;
    for (const QString& line : lines) {
        if (lineRe.match(line).hasMatch()) {
            match = line;
            break;
        }
    }

    if (match.isEmpty()) {
        return QString();
    }

    static const QRegularExpression bracketRe(QStringLiteral("\\[([^\\]]+)\\][^\\[]*$"));
    const auto bracket = bracketRe.match(match);
    if (bracket.hasMatch()) {
        return cleanName(bracket.captured(1));
    }

    // Split on a colon followed by whitespace so the PCI slot ("00:02.0") is not
    // mistaken for the class/name separator ("controller: Device").
    static const QRegularExpression colonRe(QStringLiteral(":\\s+(.+)"));
    const auto colon = colonRe.match(match);
    if (colon.hasMatch()) {
        return cleanName(colon.captured(1));
    }

    return QString();
}

struct NameSource {
    QString program;
    QStringList args;
    QString (*parse)(const QByteArray&);
};

// Name probes in priority order; the first non-empty result wins. The NVIDIA
// probe is first and doubles as the type probe (see finishNameSource).
const std::array<NameSource, 3>& nameSources() {
    static const std::array<NameSource, 3> sources = { {
        { QStringLiteral("nvidia-smi"), { QStringLiteral("--query-gpu=name"), QStringLiteral("--format=csv,noheader") },
            &parseNvidiaName },
        { QStringLiteral("glxinfo"), { QStringLiteral("-B") }, &parseGlxinfoName },
        { QStringLiteral("lspci"), {}, &parseLspciName },
    } };
    return sources;
}

// Index of the NVIDIA source within nameSources(); its result also drives type.
constexpr int kNvidiaSource = 0;

} // namespace

Gpu::Gpu(QObject* parent)
    : TickingService(parent) {
    m_busyFiles = gpuBusyFiles();

    auto* svc = caelestia::config::ConfigSingleton::instance()->services();
    m_userType = parseType(svc->gpuType());
    QObject::connect(svc, &caelestia::config::ServiceConfig::gpuTypeChanged, this, [this, svc] {
        setUserType(parseType(svc->gpuType()));
    });

    // Defer the initial GPU detection by 5 seconds to prevent waking up a runtime-suspended
    // discrete GPU (e.g., Nvidia) during Qt Wayland's initial screen enumeration.
    // If the dGPU wakes up while Qt is picking the primary screen for its animation
    // loop, Qt may lock the refresh rate to the dGPU's monitor rather than the iGPU's,
    // causing an animation refresh-rate mismatch on multi-monitor setups (Issue #169, #314).
    QTimer::singleShot(5000, this, [this] {
        detectGpu();
    });
}

Gpu::Type Gpu::type() const {
    return m_userType == Auto ? m_autoType : m_userType;
}

Gpu::Type Gpu::userType() const {
    return m_userType;
}

Gpu::Type Gpu::autoType() const {
    return m_autoType;
}

QString Gpu::name() const {
    return m_name;
}

qreal Gpu::percentage() const {
    return m_percentage;
}

qreal Gpu::temperature() const {
    return m_temperature;
}

void Gpu::setUserType(Type value) {
    if (value == m_userType) {
        return;
    }
    const Type prevDerived = type();
    m_userType = value;
    Q_EMIT userTypeChanged();
    if (type() != prevDerived) {
        Q_EMIT typeChanged();
    }

    // Probe again when switching back to auto
    if (value == Auto) {
        detectGpu();
    }
}

void Gpu::setAutoType(Type value) {
    if (value == m_autoType) {
        return;
    }
    const Type prevDerived = type();
    m_autoType = value;
    Q_EMIT autoTypeChanged();
    if (type() != prevDerived) {
        Q_EMIT typeChanged();
    }
}

void Gpu::setName(QString value) {
    if (value == m_name) {
        return;
    }
    m_name = std::move(value);
    Q_EMIT nameChanged();
}

void Gpu::tick() {
    const Type t = type();
    if (t == Generic) {
        readGenericUsage();
        readGpuTemperature();
    } else if (t == Nvidia) {
        startNvidiaUsage();
    } else {
        if (std::abs(m_percentage) > 0.0001) {
            m_percentage = 0.0;
            Q_EMIT percentageChanged();
        }
        if (std::abs(m_temperature) > 0.05) {
            m_temperature = 0.0;
            Q_EMIT temperatureChanged();
        }
    }
}

void Gpu::detectGpu() {
    if (m_detecting) {
        return;
    }
    m_detecting = true;

    // Probe in priority order, stopping at the first result
    tryNameSource(0);
}

void Gpu::tryNameSource(int index) {
    const NameSource& src = nameSources().at(static_cast<std::size_t>(index));
    runProcess(src.program, src.args, [this, index, parse = src.parse](const QByteArray& out) {
        finishNameSource(index, parse(out));
    });
}

void Gpu::finishNameSource(int index, QString name) {
    // The NVIDIA name probe doubles as the type probe: a non-empty result means an
    // NVIDIA GPU is present and queryable. Derive autoType unconditionally (even when
    // the user pins a type) so a later switch to Auto reads a correct value without
    // depending on its own re-probe, which is skipped while a probe is in flight.
    if (index == kNvidiaSource) {
        setAutoType(!name.isEmpty()
                ? Nvidia
                : (m_busyFiles.isEmpty() && !hasIntelGpu() && !hasKgslGpu() ? None : Generic));
    }

    if (!name.isEmpty()) {
        setName(std::move(name));
        m_detecting = false;
        return;
    }

    if (index + 1 < static_cast<int>(nameSources().size())) {
        tryNameSource(index + 1);
    } else {
        // glxinfo and lspci have nothing to say about an Adreno inside a
        // container; the kgsl model node does
        QFile model(QStringLiteral("/sys/class/kgsl/kgsl-3d0/gpu_model"));
        if (model.open(QIODevice::ReadOnly | QIODevice::Text)) {
            setName(cleanName(QString::fromUtf8(model.readAll().trimmed())));
            model.close();
        }
        m_detecting = false;
    }
}

void Gpu::runProcess(const QString& program, const QStringList& args, std::function<void(const QByteArray&)> callback) {
    auto* proc = new QProcess(this);
    proc->setStandardErrorFile(QProcess::nullDevice());

    // Deliver the result exactly once, then tear the process down. A crash or a
    // missing binary yields empty output so the caller can fall through gracefully:
    // only FailedToStart skips finished(), and a crash reports CrashExit there.
    const auto finish = [proc, callback = std::move(callback)](const QByteArray& out) {
        callback(out);
        proc->deleteLater();
    };

    QObject::connect(proc, &QProcess::finished, this, [finish, proc](int, QProcess::ExitStatus status) {
        finish(status == QProcess::NormalExit ? proc->readAllStandardOutput() : QByteArray());
    });
    QObject::connect(proc, &QProcess::errorOccurred, this, [finish](QProcess::ProcessError err) {
        if (err == QProcess::FailedToStart) {
            finish(QByteArray());
        }
    });

    proc->start(program, args);
}

void Gpu::readGenericUsage() {
    const QStringList cards =
        QDir(QStringLiteral("/sys/class/drm"))
            .entryList(QStringList() << QStringLiteral("card*"), QDir::Dirs | QDir::NoDotAndDotDot);

    qreal maxPerc = -1.0;

    // Pass 1: amdgpu (and some newer Xe) cards expose a direct busy percent.
    for (const QString& card : cards) {
        QFile f(QStringLiteral("/sys/class/drm/%1/device/gpu_busy_percent").arg(card));
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
            continue;
        }
        bool ok = false;
        const qreal v = f.readAll().trimmed().toDouble(&ok);
        f.close();
        if (ok && v > maxPerc) {
            maxPerc = v;
        }
    }

    // Pass 2: Intel iGPUs have no busy-percent node; approximate usage as the
    // ratio of the current GPU frequency to its maximum.
    for (const QString& card : cards) {
        if (QFile::exists(QStringLiteral("/sys/class/drm/%1/device/gpu_busy_percent").arg(card)))
            continue;
        QFile cur(QStringLiteral("/sys/class/drm/%1/gt/gt0/rps_cur_freq_mhz").arg(card));
        if (!cur.open(QIODevice::ReadOnly | QIODevice::Text)) {
            continue;
        }
        QFile max(QStringLiteral("/sys/class/drm/%1/gt/gt0/rps_max_freq_mhz").arg(card));
        if (!max.open(QIODevice::ReadOnly | QIODevice::Text)) {
            cur.close();
            continue;
        }
        bool curOk = false;
        bool maxOk = false;
        const qreal curV = cur.readAll().trimmed().toDouble(&curOk);
        const qreal maxV = max.readAll().trimmed().toDouble(&maxOk);
        cur.close();
        max.close();
        if (curOk && maxOk && maxV > 0.0) {
            qreal ratio = curV / maxV;
            if (ratio < 0.0) {
                ratio = 0.0;
            }
            if (ratio > 1.0) {
                ratio = 1.0;
            }
            const qreal v = ratio * 100.0;
            if (v > maxPerc) {
                maxPerc = v;
            }
        }
    }

    // Pass 3: kgsl (Adreno). gpu_busy_percentage is a plain "N %"; the gpubusy
    // pair is busy/total ticks over the window since the last read.
    QFile kgslBusy(QStringLiteral("/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"));
    if (!kgslBusy.open(QIODevice::ReadOnly | QIODevice::Text)) {
        kgslBusy.setFileName(QStringLiteral("/sys/class/kgsl/kgsl-3d0/gpubusy"));
        kgslBusy.open(QIODevice::ReadOnly | QIODevice::Text);
    }
    if (kgslBusy.isOpen()) {
        const bool isPair = kgslBusy.fileName().endsWith(QStringLiteral("gpubusy"));
        const QList<QByteArray> parts = kgslBusy.readAll().simplified().split(' ');
        kgslBusy.close();

        bool ok = false;
        qreal v = 0.0;
        if (isPair && parts.size() >= 2) {
            const qreal busy = parts.at(0).toDouble(&ok);
            const qreal total = parts.at(1).toDouble();
            if (ok && total > 0.0) {
                v = busy / total * 100.0;
            } else {
                ok = false;
            }
        } else {
            v = QString::fromUtf8(parts.join(' ')).remove(u'%').trimmed().toDouble(&ok);
        }
        if (ok && v > maxPerc) {
            maxPerc = v;
        }
    }

    const qreal newPerc = maxPerc >= 0.0 ? maxPerc / 100.0 : 0.0;
    if (std::abs(newPerc - m_percentage) > 0.0001) {
        m_percentage = newPerc;
        Q_EMIT percentageChanged();
    }
}

void Gpu::startNvidiaUsage() {
    if (m_nvidiaQuerying) {
        return;
    }
    m_nvidiaQuerying = true;
    runProcess(QStringLiteral("nvidia-smi"),
        { QStringLiteral("--query-gpu=utilization.gpu,temperature.gpu"),
            QStringLiteral("--format=csv,noheader,nounits") },
        [this](const QByteArray& out) {
            m_nvidiaQuerying = false;

            const QList<QByteArray> parts = out.trimmed().split(',');
            if (parts.size() < 2) {
                return;
            }
            bool ok1 = false;
            bool ok2 = false;
            const qreal usage = parts.at(0).trimmed().toDouble(&ok1) / 100.0;
            const qreal temp = parts.at(1).trimmed().toDouble(&ok2);
            if (ok1 && std::abs(usage - m_percentage) > 0.0001) {
                m_percentage = usage;
                Q_EMIT percentageChanged();
            }
            if (ok2 && std::abs(temp - m_temperature) > 0.05) {
                m_temperature = temp;
                Q_EMIT temperatureChanged();
            }
        });
}

void Gpu::readGpuTemperature() {
    // kgsl reports millidegrees in a single node; lm_sensors sees nothing
    // without a PCI GPU, so try it first
    QFile kgslTemp(QStringLiteral("/sys/class/kgsl/kgsl-3d0/temp"));
    if (kgslTemp.open(QIODevice::ReadOnly | QIODevice::Text)) {
        bool ok = false;
        const qreal milli = kgslTemp.readAll().trimmed().toDouble(&ok);
        kgslTemp.close();
        if (ok) {
            const qreal newTemp = milli / 1000.0;
            if (std::abs(newTemp - m_temperature) > 0.05) {
                m_temperature = newTemp;
                Q_EMIT temperatureChanged();
            }
            return;
        }
    }

    const auto t = sensorslib::gpuPciAverageTemp();
    const qreal newTemp = t.value_or(0.0);
    if (std::abs(newTemp - m_temperature) > 0.05) {
        m_temperature = newTemp;
        Q_EMIT temperatureChanged();
    }
}

Gpu::Type Gpu::parseType(const QString& s) {
    const QString u = s.trimmed().toUpper();
    if (u.isEmpty()) {
        return Auto;
    }
    if (u == QStringLiteral("NVIDIA")) {
        return Nvidia;
    }
    if (u == QStringLiteral("GENERIC")) {
        return Generic;
    }
    return None;
}

} // namespace caelestia::services
