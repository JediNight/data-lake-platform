# Data Lake Platform Architecture Diagrams

## 1. End-to-End Data Flow

```mermaid
flowchart TD
    subgraph SOURCE["SOURCE LAYER -- PostgreSQL Trading Database"]
        direction LR
        subgraph MNPI_TABLES["MNPI Tables"]
            T_ORD[("orders")]
            T_TRD[("trades")]
            T_POS[("positions")]
        end
        subgraph NONMNPI_TABLES["Non-MNPI Tables"]
            T_ACC[("accounts")]
            T_INS[("instruments")]
        end
    end

    subgraph CDC["CDC LAYER -- Debezium (Strimzi CRD)"]
        DEB["Debezium PostgreSQL\nSource Connector\n(SSL + WAL)"]
    end

    subgraph STREAMING["STREAMING LAYER -- External Producers"]
        SP_OE["Trading Platform\nProducer"]
        SP_MD["Market Data\nFeed Producer"]
    end

    subgraph KAFKA["KAFKA -- MSK Provisioned / Local Strimzi"]
        direction TB
        subgraph MNPI_TOPICS["MNPI Topics"]
            KT1["cdc.trading.orders"]
            KT2["cdc.trading.trades"]
            KT3["cdc.trading.positions"]
            KT4["stream.order-events"]
            KT4_DLQ["stream.order-events.dlq"]
        end
        subgraph NONMNPI_TOPICS["Non-MNPI Topics"]
            KT5["cdc.trading.accounts"]
            KT6["cdc.trading.instruments"]
            KT7["stream.market-data"]
            KT7_DLQ["stream.market-data.dlq"]
        end
    end

    subgraph SINK["SINK LAYER -- Iceberg Kafka Connect (Strimzi CRD)"]
        SINK_MNPI["Iceberg Sink MNPI\n(exactly-once, append-only)"]
        SINK_NONMNPI["Iceberg Sink Non-MNPI\n(exactly-once, append-only)"]
    end

    subgraph STORAGE["STORAGE LAYER -- S3 + KMS Encryption"]
        subgraph S3_MNPI["S3: datalake-mnpi-ENV\n(KMS CMK: mnpi)"]
            RAW_M["raw/\n(append-only Iceberg)"]
            CUR_M["curated/\n(MERGE INTO)"]
            ANA_M["analytics/\n(CTAS)"]
        end
        subgraph S3_NONMNPI["S3: datalake-nonmnpi-ENV\n(KMS CMK: nonmnpi)"]
            RAW_N["raw/\n(append-only Iceberg)"]
            CUR_N["curated/\n(MERGE INTO)"]
            ANA_N["analytics/\n(CTAS)"]
        end
    end

    subgraph CATALOG["CATALOG LAYER -- AWS Glue"]
        DB1[("raw_mnpi")]
        DB2[("curated_mnpi")]
        DB3[("analytics_mnpi")]
        DB4[("raw_nonmnpi")]
        DB5[("curated_nonmnpi")]
        DB6[("analytics_nonmnpi")]
    end

    subgraph ACCESS["ACCESS LAYER -- Lake Formation + Athena"]
        subgraph LFTAGS["LF-Tags (ABAC)"]
            TAG_S["sensitivity:\nmnpi | non-mnpi"]
            TAG_L["layer:\nraw | curated | analytics"]
        end
        subgraph WORKGROUPS["Athena Workgroups"]
            WG_FIN["finance-analysts\n(scan-limited)"]
            WG_DA["data-analysts\n(scan-limited)"]
            WG_DE["data-engineers\n(unlimited)"]
        end
        subgraph PERSONAS["IAM Personas"]
            P_FIN["Finance Analyst\nMNPI+non-MNPI\ncurated+analytics"]
            P_DA["Data Analyst\nnon-MNPI only\ncurated+analytics"]
            P_DE["Data Engineer\nall zones, all layers\n+ direct S3"]
        end
    end

    subgraph AUDIT["AUDIT LAYER -- CloudTrail"]
        CT["CloudTrail\n(S3 data events +\nLF audit logs)"]
        S3_AUDIT[("S3: datalake-audit-ENV")]
        CW["CloudWatch Logs\n(real-time alerts)"]
    end

    %% Source to CDC
    T_ORD --> DEB
    T_TRD --> DEB
    T_POS --> DEB
    T_ACC --> DEB
    T_INS --> DEB

    %% CDC to Kafka Topics
    DEB --> KT1
    DEB --> KT2
    DEB --> KT3
    DEB --> KT5
    DEB --> KT6

    %% Streaming to Kafka Topics
    SP_OE --> KT4
    SP_MD --> KT7

    %% Kafka Topics to Sinks
    KT1 --> SINK_MNPI
    KT2 --> SINK_MNPI
    KT3 --> SINK_MNPI
    KT4 --> SINK_MNPI
    KT5 --> SINK_NONMNPI
    KT6 --> SINK_NONMNPI
    KT7 --> SINK_NONMNPI

    %% Sinks to Storage
    SINK_MNPI -->|"IRSA-scoped\nS3 write"| RAW_M
    SINK_NONMNPI -->|"IRSA-scoped\nS3 write"| RAW_N

    %% Medallion transforms
    RAW_M -->|"MERGE INTO\n(Athena SQL)"| CUR_M
    CUR_M -->|"CTAS\n(Athena SQL)"| ANA_M
    RAW_N -->|"MERGE INTO\n(Athena SQL)"| CUR_N
    CUR_N -->|"CTAS\n(Athena SQL)"| ANA_N

    %% Storage to Catalog
    RAW_M -.- DB1
    CUR_M -.- DB2
    ANA_M -.- DB3
    RAW_N -.- DB4
    CUR_N -.- DB5
    ANA_N -.- DB6

    %% Catalog to LF-Tags
    DB1 -.- TAG_S
    DB1 -.- TAG_L
    DB6 -.- TAG_S
    DB6 -.- TAG_L

    %% LF-Tags to Workgroups to Personas
    TAG_S --- WG_FIN
    TAG_L --- WG_FIN
    TAG_S --- WG_DA
    TAG_L --- WG_DA
    TAG_S --- WG_DE
    TAG_L --- WG_DE
    WG_FIN --- P_FIN
    WG_DA --- P_DA
    WG_DE --- P_DE

    %% Audit
    S3_MNPI -.->|"data events"| CT
    S3_NONMNPI -.->|"data events"| CT
    CT --> S3_AUDIT
    CT --> CW

    %% Styling
    classDef mnpi fill:#ffcccc,stroke:#cc0000,color:#000
    classDef nonmnpi fill:#ccffcc,stroke:#009900,color:#000
    classDef kafka fill:#e6e0f8,stroke:#6633cc,color:#000
    classDef audit fill:#fff3cd,stroke:#cc9900,color:#000
    classDef storage fill:#cce5ff,stroke:#0066cc,color:#000

    class T_ORD,T_TRD,T_POS,KT1,KT2,KT3,KT4,KT4_DLQ,SINK_MNPI,S3_MNPI,RAW_M,CUR_M,ANA_M,DB1,DB2,DB3 mnpi
    class T_ACC,T_INS,KT5,KT6,KT7,KT7_DLQ,SINK_NONMNPI,S3_NONMNPI,RAW_N,CUR_N,ANA_N,DB4,DB5,DB6 nonmnpi
    class KAFKA,MNPI_TOPICS,NONMNPI_TOPICS kafka
    class CT,S3_AUDIT,CW audit
```

---

## 2. MNPI / Non-MNPI Isolation Boundary

```mermaid
flowchart LR
    subgraph MNPI_ZONE["MNPI ZONE (Red)"]
        direction TB
        M_SRC["orders, trades, positions\n+ stream.order-events"]
        M_TOPICS["MNPI Kafka Topics\n(4 topics)"]
        M_SINK["Iceberg Sink MNPI"]
        M_S3["S3 MNPI Bucket\n(dedicated KMS CMK)"]
        M_GLUE["raw_mnpi\ncurated_mnpi\nanalytics_mnpi"]

        M_SRC --> M_TOPICS --> M_SINK --> M_S3 --> M_GLUE
    end

    subgraph NONMNPI_ZONE["NON-MNPI ZONE (Green)"]
        direction TB
        N_SRC["accounts, instruments\n+ stream.market-data"]
        N_TOPICS["Non-MNPI Kafka Topics\n(3 topics)"]
        N_SINK["Iceberg Sink Non-MNPI"]
        N_S3["S3 Non-MNPI Bucket\n(dedicated KMS CMK)"]
        N_GLUE["raw_nonmnpi\ncurated_nonmnpi\nanalytics_nonmnpi"]

        N_SRC --> N_TOPICS --> N_SINK --> N_S3 --> N_GLUE
    end

    WALL["ISOLATION BOUNDARY\n\nSeparate topics\nSeparate sink connectors\nSeparate S3 buckets\nSeparate KMS keys\nSeparate LF-Tag values\nBucket deny policies"]

    MNPI_ZONE ~~~ WALL ~~~ NONMNPI_ZONE

    classDef mnpi fill:#ffcccc,stroke:#cc0000,color:#000
    classDef nonmnpi fill:#ccffcc,stroke:#009900,color:#000
    classDef wall fill:#ffffcc,stroke:#cc6600,color:#000,font-weight:bold

    class M_SRC,M_TOPICS,M_SINK,M_S3,M_GLUE mnpi
    class N_SRC,N_TOPICS,N_SINK,N_S3,N_GLUE nonmnpi
    class WALL wall
```

---

## 3. Access Control Matrix -- Persona to LF-Tags to Databases

```mermaid
flowchart LR
    subgraph PERSONAS["IAM Personas"]
        FIN["Finance Analyst"]
        DA["Data Analyst"]
        DE["Data Engineer"]
    end

    subgraph LFTAG_GRANTS["LF-Tag Grants (AND logic)"]
        G_FIN["sensitivity: mnpi, non-mnpi\nlayer: curated, analytics\npermission: SELECT"]
        G_DA["sensitivity: non-mnpi\nlayer: curated, analytics\npermission: SELECT"]
        G_DE["sensitivity: mnpi, non-mnpi\nlayer: raw, curated, analytics\npermission: ALL\n+ DATA_LOCATION_ACCESS"]
    end

    subgraph DATABASES["Glue Catalog Databases"]
        DB_RM["raw_mnpi"]
        DB_RN["raw_nonmnpi"]
        DB_CM["curated_mnpi"]
        DB_CN["curated_nonmnpi"]
        DB_AM["analytics_mnpi"]
        DB_AN["analytics_nonmnpi"]
    end

    FIN --> G_FIN
    DA --> G_DA
    DE --> G_DE

    G_FIN -->|"ALLOWED"| DB_CM
    G_FIN -->|"ALLOWED"| DB_CN
    G_FIN -->|"ALLOWED"| DB_AM
    G_FIN -->|"ALLOWED"| DB_AN

    G_DA -->|"ALLOWED"| DB_CN
    G_DA -->|"ALLOWED"| DB_AN

    G_DE -->|"ALLOWED"| DB_RM
    G_DE -->|"ALLOWED"| DB_RN
    G_DE -->|"ALLOWED"| DB_CM
    G_DE -->|"ALLOWED"| DB_CN
    G_DE -->|"ALLOWED"| DB_AM
    G_DE -->|"ALLOWED"| DB_AN

    classDef mnpi fill:#ffcccc,stroke:#cc0000,color:#000
    classDef nonmnpi fill:#ccffcc,stroke:#009900,color:#000
    classDef persona fill:#ddeeff,stroke:#3366cc,color:#000
    classDef grant fill:#f0e6ff,stroke:#6633cc,color:#000

    class DB_RM,DB_CM,DB_AM mnpi
    class DB_RN,DB_CN,DB_AN nonmnpi
    class FIN,DA,DE persona
    class G_FIN,G_DA,G_DE grant
```

---

## 4. Access Control Summary Table

| Database | Finance Analyst | Data Analyst | Data Engineer |
|----------|:-:|:-:|:-:|
| `raw_mnpi` | DENIED | DENIED | ALL |
| `raw_nonmnpi` | DENIED | DENIED | ALL |
| `curated_mnpi` | SELECT | DENIED | ALL |
| `curated_nonmnpi` | SELECT | SELECT | ALL |
| `analytics_mnpi` | SELECT | DENIED | ALL |
| `analytics_nonmnpi` | SELECT | SELECT | ALL |

**Legend:** DENIED = Lake Formation blocks the query. SELECT = read-only via Athena. ALL = full access including DDL, plus direct S3 for Data Engineer.

---

## 5. Terraform Module Dependency Graph

```mermaid
flowchart TD
    NET["networking\nVPC, subnets, SGs,\nS3 gateway endpoint"]
    STR["streaming\nMSK Provisioned cluster"]
    DLS["data-lake-storage\nS3 buckets, KMS keys,\nbucket deny policies"]
    GLU["glue-catalog\n6 Glue databases,\nschema registry"]
    IAM["iam-personas\n3 persona roles,\nservice roles"]
    LF["lake-formation\nLF-Tags, grants,\nS3 registrations"]
    ANA["analytics\nAthena workgroups,\nnamed queries"]
    OBS["observability\nCloudTrail, audit bucket,\nCloudWatch"]

    NET --> STR
    NET --> DLS
    DLS --> GLU
    DLS --> IAM
    DLS --> OBS
    DLS --> ANA
    IAM --> LF
    GLU --> LF

    classDef infra fill:#e8e8e8,stroke:#666,color:#000
    classDef data fill:#cce5ff,stroke:#0066cc,color:#000
    classDef access fill:#f0e6ff,stroke:#6633cc,color:#000
    classDef audit fill:#fff3cd,stroke:#cc9900,color:#000

    class NET,STR infra
    class DLS,GLU data
    class IAM,LF,ANA access
    class OBS audit
```

---

## 6. Medallion Layer Detail

```mermaid
flowchart LR
    subgraph RAW["Raw Layer"]
        direction TB
        R_DESC["Append-only Iceberg tables\nFull CDC event history\nPartitioned by days(source_timestamp)\nWrite: Kafka Connect sink"]
        R_TABLES["orders | trades | positions\naccounts | instruments\n+ streaming tables"]
    end

    subgraph CURATED["Curated Layer"]
        direction TB
        C_DESC["Current-state tables\nDeduplicated via MERGE INTO\nPartitioned by days(updated_at)\nWrite: Athena SQL"]
        C_TABLES["orders | trades | positions\naccounts | instruments"]
    end

    subgraph ANALYTICS["Analytics Layer"]
        direction TB
        A_DESC["Pre-aggregated reports\nFull rebuild via CTAS\nPartitioned by months(report_date)\nWrite: Athena SQL"]
        A_TABLES["daily_trade_summary\nposition_report"]
    end

    RAW -->|"MERGE INTO\n(latest event per PK)"| CURATED
    CURATED -->|"CTAS\n(aggregation queries)"| ANALYTICS

    classDef raw fill:#fff0e0,stroke:#cc6600,color:#000
    classDef curated fill:#e0f0ff,stroke:#0066cc,color:#000
    classDef analytics fill:#e0ffe0,stroke:#009900,color:#000

    class RAW,R_DESC,R_TABLES raw
    class CURATED,C_DESC,C_TABLES curated
    class ANALYTICS,A_DESC,A_TABLES analytics
```
