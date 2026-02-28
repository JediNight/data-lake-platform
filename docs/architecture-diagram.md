# Data Lake Platform Architecture Diagrams

## 1. End-to-End Data Flow

```mermaid
flowchart TD
    subgraph SOURCE["Source Layer: PostgreSQL Trading DB"]
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

    subgraph CDC["CDC Layer: Debezium via Strimzi"]
        DEB["Debezium PostgreSQL\nSource Connector"]
    end

    subgraph STREAMING["Streaming Layer: External Producers"]
        SP_OE["Trading Platform\nProducer"]
        SP_MD["Market Data\nFeed Producer"]
    end

    PRODUCER["Producer API\nFastAPI + Simulator"]

    subgraph KAFKA["Kafka: MSK Provisioned / Local Strimzi"]
        subgraph MNPI_TOPICS["MNPI Topics"]
            KT1["cdc.trading.orders"]
            KT2["cdc.trading.trades"]
            KT3["cdc.trading.positions"]
            KT4["stream.order-events"]
        end
        subgraph NONMNPI_TOPICS["Non-MNPI Topics"]
            KT5["cdc.trading.accounts"]
            KT6["cdc.trading.instruments"]
            KT7["stream.market-data"]
        end
    end

    subgraph SINK["Sink Layer: Iceberg Kafka Connect"]
        SINK_MNPI["Iceberg Sink MNPI\nappend-only"]
        SINK_NONMNPI["Iceberg Sink Non-MNPI\nappend-only"]
    end

    subgraph STORAGE["Storage Layer: S3 with KMS Encryption"]
        subgraph S3_MNPI["S3: datalake-mnpi-ENV"]
            RAW_M["raw/"]
            CUR_M["curated/"]
            ANA_M["analytics/"]
        end
        subgraph S3_NONMNPI["S3: datalake-nonmnpi-ENV"]
            RAW_N["raw/"]
            CUR_N["curated/"]
            ANA_N["analytics/"]
        end
    end

    subgraph CATALOG["Catalog Layer: AWS Glue"]
        DB1[("raw_mnpi")]
        DB2[("curated_mnpi")]
        DB3[("analytics_mnpi")]
        DB4[("raw_nonmnpi")]
        DB5[("curated_nonmnpi")]
        DB6[("analytics_nonmnpi")]
    end

    subgraph ACCESS["Access Layer: Lake Formation and Athena"]
        subgraph LFTAGS["LF-Tags ABAC"]
            TAG_S["sensitivity:\nmnpi / non-mnpi"]
            TAG_L["layer:\nraw / curated / analytics"]
        end
        subgraph WORKGROUPS["Athena Workgroups"]
            WG_FIN["finance-analysts"]
            WG_DA["data-analysts"]
            WG_DE["data-engineers"]
        end
        subgraph PERSONAS["IAM Personas"]
            P_FIN["Finance Analyst"]
            P_DA["Data Analyst"]
            P_DE["Data Engineer"]
        end
    end

    subgraph AUDIT["Audit Layer: CloudTrail"]
        CT["CloudTrail"]
        S3_AUDIT[("S3: datalake-audit-ENV")]
        CW["CloudWatch Logs"]
    end

    T_ORD --> DEB
    T_TRD --> DEB
    T_POS --> DEB
    T_ACC --> DEB
    T_INS --> DEB

    DEB --> KT1
    DEB --> KT2
    DEB --> KT3
    DEB --> KT5
    DEB --> KT6

    SP_OE --> KT4
    SP_MD --> KT7

    PRODUCER -->|"INSERT"| SOURCE
    PRODUCER -->|"produce"| KT4
    PRODUCER -->|"produce"| KT7

    KT1 --> SINK_MNPI
    KT2 --> SINK_MNPI
    KT3 --> SINK_MNPI
    KT4 --> SINK_MNPI
    KT5 --> SINK_NONMNPI
    KT6 --> SINK_NONMNPI
    KT7 --> SINK_NONMNPI

    SINK_MNPI -->|"IRSA write"| RAW_M
    SINK_NONMNPI -->|"IRSA write"| RAW_N

    RAW_M -->|"MERGE INTO"| CUR_M
    CUR_M -->|"CTAS"| ANA_M
    RAW_N -->|"MERGE INTO"| CUR_N
    CUR_N -->|"CTAS"| ANA_N

    RAW_M -.- DB1
    CUR_M -.- DB2
    ANA_M -.- DB3
    RAW_N -.- DB4
    CUR_N -.- DB5
    ANA_N -.- DB6

    DB1 -.- TAG_S
    DB6 -.- TAG_L

    TAG_S --- WG_FIN
    TAG_L --- WG_FIN
    TAG_S --- WG_DA
    TAG_L --- WG_DA
    TAG_S --- WG_DE
    TAG_L --- WG_DE
    WG_FIN --- P_FIN
    WG_DA --- P_DA
    WG_DE --- P_DE

    S3_MNPI -.->|"data events"| CT
    S3_NONMNPI -.->|"data events"| CT
    CT --> S3_AUDIT
    CT --> CW

    classDef mnpi fill:#ffcccc,stroke:#cc0000,color:#000
    classDef nonmnpi fill:#ccffcc,stroke:#009900,color:#000
    classDef kafka fill:#e6e0f8,stroke:#6633cc,color:#000
    classDef audit fill:#fff3cd,stroke:#cc9900,color:#000
    classDef producer fill:#ddeeff,stroke:#3366cc,color:#000

    class T_ORD,T_TRD,T_POS,KT1,KT2,KT3,KT4,SINK_MNPI,RAW_M,CUR_M,ANA_M,DB1,DB2,DB3 mnpi
    class T_ACC,T_INS,KT5,KT6,KT7,SINK_NONMNPI,RAW_N,CUR_N,ANA_N,DB4,DB5,DB6 nonmnpi
    class KAFKA,MNPI_TOPICS,NONMNPI_TOPICS kafka
    class CT,S3_AUDIT,CW audit
    class PRODUCER producer
```

---

## 2. MNPI / Non-MNPI Isolation Boundary

```mermaid
flowchart LR
    subgraph MNPI_ZONE["MNPI Zone"]
        M_SRC["orders, trades, positions\n+ stream.order-events"]
        M_TOPICS["MNPI Kafka Topics\n4 topics"]
        M_SINK["Iceberg Sink MNPI"]
        M_S3["S3 MNPI Bucket\ndedicated KMS CMK"]
        M_GLUE["raw_mnpi\ncurated_mnpi\nanalytics_mnpi"]

        M_SRC --> M_TOPICS --> M_SINK --> M_S3 --> M_GLUE
    end

    subgraph NONMNPI_ZONE["Non-MNPI Zone"]
        N_SRC["accounts, instruments\n+ stream.market-data"]
        N_TOPICS["Non-MNPI Kafka Topics\n3 topics"]
        N_SINK["Iceberg Sink Non-MNPI"]
        N_S3["S3 Non-MNPI Bucket\ndedicated KMS CMK"]
        N_GLUE["raw_nonmnpi\ncurated_nonmnpi\nanalytics_nonmnpi"]

        N_SRC --> N_TOPICS --> N_SINK --> N_S3 --> N_GLUE
    end

    WALL["ISOLATION BOUNDARY\nSeparate topics\nSeparate sink connectors\nSeparate S3 buckets\nSeparate KMS keys\nSeparate LF-Tag values\nBucket deny policies"]

    MNPI_ZONE -.- WALL
    WALL -.- NONMNPI_ZONE

    classDef mnpi fill:#ffcccc,stroke:#cc0000,color:#000
    classDef nonmnpi fill:#ccffcc,stroke:#009900,color:#000
    classDef wall fill:#ffffcc,stroke:#cc6600,color:#000

    class M_SRC,M_TOPICS,M_SINK,M_S3,M_GLUE mnpi
    class N_SRC,N_TOPICS,N_SINK,N_S3,N_GLUE nonmnpi
    class WALL wall
```

---

## 3. Access Control Matrix: Persona to LF-Tags to Databases

```mermaid
flowchart LR
    subgraph PERSONAS["IAM Personas"]
        FIN["Finance Analyst"]
        DA["Data Analyst"]
        DE["Data Engineer"]
    end

    subgraph LFTAG_GRANTS["LF-Tag Grants"]
        G_FIN["sensitivity: mnpi, non-mnpi\nlayer: curated, analytics\npermission: SELECT"]
        G_DA["sensitivity: non-mnpi\nlayer: curated, analytics\npermission: SELECT"]
        G_DE["sensitivity: mnpi, non-mnpi\nlayer: raw, curated, analytics\npermission: ALL"]
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
        R_DESC["Append-only Iceberg tables\nFull CDC event history\nPartitioned by source_timestamp\nWrite: Kafka Connect sink"]
        R_TABLES["orders / trades / positions\naccounts / instruments\n+ streaming tables"]
    end

    subgraph CURATED["Curated Layer"]
        C_DESC["Current-state tables\nDeduplicated via MERGE INTO\nPartitioned by updated_at\nWrite: Athena SQL"]
        C_TABLES["orders / trades / positions\naccounts / instruments"]
    end

    subgraph ANALYTICS["Analytics Layer"]
        A_DESC["Pre-aggregated reports\nFull rebuild via CTAS\nPartitioned by report_date\nWrite: Athena SQL"]
        A_TABLES["daily_trade_summary\nposition_report"]
    end

    RAW -->|"MERGE INTO\nlatest event per PK"| CURATED
    CURATED -->|"CTAS\naggregation queries"| ANALYTICS

    classDef raw fill:#fff0e0,stroke:#cc6600,color:#000
    classDef curated fill:#e0f0ff,stroke:#0066cc,color:#000
    classDef analytics fill:#e0ffe0,stroke:#009900,color:#000

    class RAW,R_DESC,R_TABLES raw
    class CURATED,C_DESC,C_TABLES curated
    class ANALYTICS,A_DESC,A_TABLES analytics
```
